/* d3d9: the same scene as d3d11 with Direct3D 9 (fixed-function, pre-transformed vertices, no shaders).
 *
 * Per frame: `draws` DrawPrimitive calls of `tris` triangles each from one static vertex buffer, then
 * `overdraw` alpha-blended full-screen quads. Presents with D3DPRESENT_INTERVAL_IMMEDIATE.
 * Two phases, each 1 s warm-up + [seconds] measured: "present" (Present every frame: what a game sees, including
 * any display-rate cap) and "offscreen" (no Present, at most 3 frames in flight via event queries: CPU+GPU
 * throughput without the presentation path).
 *
 *   d3d9 [seconds=8] [draws=2000] [tris=100] [overdraw=8] [width=1280] [height=720]
 */
#define COBJMACROS
#define INITGUID
#include "common.h"
#include <d3d9.h>

typedef struct { float x, y, z, rhw; DWORD color; } Vtx;
#define FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)

static struct {
    IDirect3DDevice9 *dev; IDirect3DVertexBuffer9 *vb; IDirect3DQuery9 *q[16]; int qi, qn, depth;
    int draws, tris, overdraw; Vtx *quad;
} g;

/* One frame. With present=0 it waits for the frame 3 back instead of presenting (see frame_phase). */
static int frame(int present) {
    IDirect3DDevice9 *dev = g.dev;
    IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(13, 13, 15), 1.0f, 0);
    IDirect3DDevice9_BeginScene(dev);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ALPHABLENDENABLE, FALSE);
    IDirect3DDevice9_SetStreamSource(dev, 0, g.vb, 0, sizeof(Vtx));
    for (int d = 0; d < g.draws; d++)
        IDirect3DDevice9_DrawPrimitive(dev, D3DPT_TRIANGLELIST, (UINT)d * g.tris * 3, g.tris);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ALPHABLENDENABLE, TRUE);
    for (int k = 0; k < g.overdraw; k++)
        IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2, g.quad + (k % 4) * 4, sizeof(Vtx));
    IDirect3DDevice9_EndScene(dev);
    if (present) {
        HRESULT hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) { printf("ERROR Present failed: 0x%08lx\n", (unsigned long)hr); return 0; }
        return 1;
    }
    IDirect3DQuery9 *q = g.q[g.qi];
    if (g.qn >= g.depth) while (IDirect3DQuery9_GetData(q, NULL, 0, D3DGETDATA_FLUSH) == S_FALSE) {}
    IDirect3DQuery9_Issue(q, D3DISSUE_END);
    g.qi = (g.qi + 1) % g.depth;
    if (g.qn < g.depth) g.qn++;
    return 1;
}

#define CHECK(call) do { HRESULT hr_ = (call); if (FAILED(hr_)) { \
    printf("ERROR %s failed: 0x%08lx\n", #call, (unsigned long)hr_); return 4; } } while (0)

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    double t_start = now_ms();
    double seconds = argc > 1 ? atof(argv[1]) : 8;
    int draws = argc > 2 ? atoi(argv[2]) : 2000;
    int tris = argc > 3 ? atoi(argv[3]) : 100;
    int overdraw = argc > 4 ? atoi(argv[4]) : 8;
    int W = argc > 5 ? atoi(argv[5]) : 1280, H = argc > 6 ? atoi(argv[6]) : 720;
    printf("d3d9: %.1f s, %d draws x %d triangles, %d full-screen layers, %dx%d\n", seconds, draws, tris, overdraw, W, H);

    HWND hwnd = bench_window("UniveBench D3D9", W, H);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("ERROR Direct3DCreate9 returned NULL\n"); return 2; }
    D3DADAPTER_IDENTIFIER9 id = {0};
    IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id);
    HMODULE mod = GetModuleHandleA("d3d9.dll");
    char path[MAX_PATH] = "?";
    if (mod) GetModuleFileNameA(mod, path, MAX_PATH);
    printf("INFO adapter=\"%s\" driver=\"%s\" vendor=0x%04lx device=0x%04lx d3d9=%s\n", id.Description, id.Driver,
           id.VendorId, id.DeviceId, path);

    D3DPRESENT_PARAMETERS pp = {0};
    pp.BackBufferWidth = W;
    pp.BackBufferHeight = H;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = hwnd;
    pp.Windowed = TRUE;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev = NULL;
    double t_dev = now_ms();
    CHECK(IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_HARDWARE_VERTEXPROCESSING,
                                  &pp, &dev));
    result("device_create", now_ms() - t_dev, "ms");

    /* Same grid as d3d11: total triangles laid out 16:9, each ~45% of a cell. */
    unsigned total = (unsigned)draws * (unsigned)tris;
    unsigned cols = 1;
    while ((double)cols * cols * 9 < (double)total * 16) cols++;
    unsigned rows = (total + cols - 1) / cols;
    float cw = (float)W / cols, ch = (float)H / rows;
    IDirect3DVertexBuffer9 *vb = NULL;
    CHECK(IDirect3DDevice9_CreateVertexBuffer(dev, total * 3 * sizeof(Vtx), D3DUSAGE_WRITEONLY, FVF, D3DPOOL_DEFAULT, &vb, NULL));
    Vtx *v = NULL;
    CHECK(IDirect3DVertexBuffer9_Lock(vb, 0, 0, (void **)&v, 0));
    for (unsigned i = 0; i < total; i++) {
        float cx = (i % cols + 0.5f) * cw, cy = (i / cols + 0.5f) * ch;
        float sx = 0.45f * cw, sy = 0.45f * ch;
        unsigned h = i * 2654435761u;
        DWORD col = 0xff000000u | (((h >> 8) & 255) << 16) | (((h >> 16) & 255) << 8) | ((h >> 24) & 255);
        Vtx a = {cx - sx, cy + sy, 0, 1, col}, b = {cx, cy - sy, 0, 1, col}, c = {cx + sx, cy + sy, 0, 1, col};
        v[i * 3] = a; v[i * 3 + 1] = b; v[i * 3 + 2] = c;
    }
    IDirect3DVertexBuffer9_Unlock(vb);

    Vtx quad[4][4];
    for (int k = 0; k < 4; k++) {
        DWORD col = (0x14u << 24) | ((DWORD)(0x4c * (k % 3)) << 16) | (0x33 << 8) | 0x80;
        Vtx q[4] = {{0, 0, 0, 1, col}, {(float)W, 0, 0, 1, col}, {0, (float)H, 0, 1, col}, {(float)W, (float)H, 0, 1, col}};
        memcpy(quad[k], q, sizeof q);
    }

    IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, D3DZB_FALSE);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
    IDirect3DDevice9_SetRenderState(dev, D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
    IDirect3DDevice9_SetFVF(dev, FVF);

    g.dev = dev; g.vb = vb; g.draws = draws; g.tris = tris; g.overdraw = overdraw; g.quad = &quad[0][0];
    g.depth = getenv("BENCH_INFLIGHT") ? atoi(getenv("BENCH_INFLIGHT")) : 3;
    if (g.depth < 1 || g.depth > 16) g.depth = 3;
    for (int i = 0; i < g.depth; i++) CHECK(IDirect3DDevice9_CreateQuery(dev, D3DQUERYTYPE_EVENT, &g.q[i]));

    if (!frame(1)) return 5;
    result("first_frame", now_ms() - t_start, "ms");
    { double t = now_ms(); for (int i = 0; i < 2000; i++) bench_pump(); result("peekmessage", (now_ms() - t) * 1000.0 / 2000, "us/call"); }
    if (!frame_phase("present", 1, seconds, frame, bench_pump)) return 5;
    if (!frame_phase("offscreen", 0, seconds, frame, bench_pump)) return 5;
    DestroyWindow(hwnd);
    printf("d3d9: done\n");
    return 0;
}
