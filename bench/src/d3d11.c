/* d3d11: a fixed Direct3D 11 scene rendered as fast as possible for a set time.
 *
 * Per frame: `draws` draw calls of `inst` instanced triangles each (a constant-buffer update before every draw,
 * so it also measures draw-call overhead), then `overdraw` alpha-blended full-screen triangles (fill rate).
 * Presents with sync interval 0.
 * Two phases, each 1 s warm-up + [seconds] measured: "present" (Present every frame: what a game sees, including
 * any display-rate cap) and "offscreen" (no Present, at most 3 frames in flight via event queries: CPU+GPU
 * throughput without the presentation path). Shaders are compiled at start-up with D3DCompile (Wine's d3dcompiler_47).
 *
 *   d3d11 [seconds=8] [draws=2000] [inst=100] [overdraw=8] [width=1280] [height=720]
 */
#define COBJMACROS
#define INITGUID
#include "common.h"
#include <d3d11.h>
#include <d3dcompiler.h>

static const char hlsl[] =
    "cbuffer CB : register(b0) { uint base; uint cols; uint rows; float size; };\n"
    "struct V { float4 pos : SV_Position; float4 col : COLOR; };\n"
    "static const float2 offs[3] = { float2(-1,-1), float2(0,1), float2(1,-1) };\n"
    "V vs_tri(uint vid : SV_VertexID, uint iid : SV_InstanceID) {\n"
    "  uint i = base + iid;\n"
    "  float2 cell = float2(i % cols, i / cols);\n"
    "  float2 c = (cell + 0.5) / float2(cols, rows) * 2.0 - 1.0;\n"
    "  V o; o.pos = float4(c + offs[vid] * size, 0, 1);\n"
    "  uint h = i * 2654435761u;\n"
    "  o.col = float4(((h >> 8) & 255) / 255.0, ((h >> 16) & 255) / 255.0, ((h >> 24) & 255) / 255.0, 1);\n"
    "  return o;\n"
    "}\n"
    "V vs_full(uint vid : SV_VertexID, uint iid : SV_InstanceID) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "  V o; o.pos = float4(p * 2.0 - 1.0, 0, 1);\n"
    "  o.col = float4(0.3 * (iid % 3), 0.2, 0.5, 0.08);\n"
    "  return o;\n"
    "}\n"
    "float4 ps_main(V i) : SV_Target { return i.col; }\n";

typedef HRESULT (WINAPI *PFN_COMPILE)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *,
                                      LPCSTR, LPCSTR, UINT, UINT, ID3DBlob **, ID3DBlob **);

static ID3DBlob *compile(PFN_COMPILE fn, const char *entry, const char *target) {
    ID3DBlob *code = NULL, *err = NULL;
    HRESULT hr = fn(hlsl, sizeof hlsl - 1, "bench.hlsl", NULL, NULL, entry, target, 0, 0, &code, &err);
    if (FAILED(hr)) {
        printf("ERROR D3DCompile(%s) failed: 0x%08lx %s\n", entry, (unsigned long)hr,
               err ? (const char *)ID3D10Blob_GetBufferPointer(err) : "");
        exit(3);
    }
    return code;
}

static struct {
    ID3D11DeviceContext *ctx; IDXGISwapChain *sc; ID3D11RenderTargetView *rtv; ID3D11RasterizerState *rs;
    ID3D11VertexShader *vs, *vsf; ID3D11PixelShader *ps; ID3D11Buffer *cb; ID3D11BlendState *blend;
    ID3D11Query *q[16]; int qi, qn, depth;
    D3D11_VIEWPORT vp; int draws, inst, overdraw; unsigned cols, rows; float size;
} g;

/* One frame. With present=0 it waits for the frame 3 back instead of presenting (see frame_phase). */
static int frame(int present) {
    ID3D11DeviceContext *ctx = g.ctx;
    const float clear[4] = {0.05f, 0.05f, 0.06f, 1};
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &g.rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &g.vp);
    ID3D11DeviceContext_RSSetState(ctx, g.rs);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, g.rtv, clear);
    ID3D11DeviceContext_IASetInputLayout(ctx, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, g.vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &g.cb);
    ID3D11DeviceContext_PSSetShader(ctx, g.ps, NULL, 0);
    ID3D11DeviceContext_OMSetBlendState(ctx, NULL, NULL, 0xffffffff);
    for (int d = 0; d < g.draws; d++) {
        D3D11_MAPPED_SUBRESOURCE m;
        if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)g.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
            unsigned *u = m.pData;
            u[0] = (unsigned)d * (unsigned)g.inst; u[1] = g.cols; u[2] = g.rows;
            memcpy(&u[3], &g.size, 4);
            ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)g.cb, 0);
        }
        ID3D11DeviceContext_DrawInstanced(ctx, 3, g.inst, 0, 0);
    }
    if (g.overdraw > 0) {
        ID3D11DeviceContext_VSSetShader(ctx, g.vsf, NULL, 0);
        ID3D11DeviceContext_OMSetBlendState(ctx, g.blend, NULL, 0xffffffff);
        ID3D11DeviceContext_DrawInstanced(ctx, 3, g.overdraw, 0, 0);
    }
    if (present) {
        HRESULT hr = IDXGISwapChain_Present(g.sc, 0, 0);
        if (FAILED(hr)) { printf("ERROR Present failed: 0x%08lx\n", (unsigned long)hr); return 0; }
        return 1;
    }
    ID3D11Query *q = g.q[g.qi];
    if (g.qn >= g.depth) while (ID3D11DeviceContext_GetData(ctx, (ID3D11Asynchronous *)q, NULL, 0, 0) == S_FALSE) {}
    ID3D11DeviceContext_End(ctx, (ID3D11Asynchronous *)q);
    ID3D11DeviceContext_Flush(ctx);
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
    int inst = argc > 3 ? atoi(argv[3]) : 100;
    int overdraw = argc > 4 ? atoi(argv[4]) : 8;
    int W = argc > 5 ? atoi(argv[5]) : 1280, H = argc > 6 ? atoi(argv[6]) : 720;
    printf("d3d11: %.1f s, %d draws x %d triangles, %d full-screen layers, %dx%d\n", seconds, draws, inst, overdraw, W, H);

    HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
    PFN_COMPILE D3DCompileFn = dc ? (PFN_COMPILE)GetProcAddress(dc, "D3DCompile") : NULL;
    if (!D3DCompileFn) { printf("ERROR d3dcompiler_47.dll / D3DCompile not available\n"); return 2; }

    HWND hwnd = bench_window("UniveBench D3D11", W, H);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferDesc.Width = W;
    sd.BufferDesc.Height = H;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.OutputWindow = hwnd;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL level;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    double t_dev = now_ms();
    CHECK(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 3, D3D11_SDK_VERSION,
                                        &sd, &sc, &dev, &level, &ctx));
    result("device_create", now_ms() - t_dev, "ms");

    IDXGIDevice *xdev = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC ad = {0};
    char name[256] = "?";
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&xdev)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(xdev, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &ad)))
        wide_to_utf8(ad.Description, name, sizeof name);
    HMODULE d3d11mod = GetModuleHandleA("d3d11.dll");
    char d3d11path[MAX_PATH] = "?";
    if (d3d11mod) GetModuleFileNameA(d3d11mod, d3d11path, MAX_PATH);
    printf("INFO adapter=\"%s\" vendor=0x%04x device=0x%04x vram=%lluMiB feature_level=0x%x d3d11=%s\n", name,
           ad.VendorId, ad.DeviceId, (unsigned long long)(ad.DedicatedVideoMemory >> 20), level, d3d11path);

    ID3D11Texture2D *bb = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    CHECK(IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb));
    CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv));

    double t_sh = now_ms();
    ID3DBlob *b_vs = compile(D3DCompileFn, "vs_tri", "vs_4_0");
    ID3DBlob *b_full = compile(D3DCompileFn, "vs_full", "vs_4_0");
    ID3DBlob *b_ps = compile(D3DCompileFn, "ps_main", "ps_4_0");
    ID3D11VertexShader *vs = NULL, *vsf = NULL;
    ID3D11PixelShader *ps = NULL;
    CHECK(ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b_vs), ID3D10Blob_GetBufferSize(b_vs), NULL, &vs));
    CHECK(ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(b_full), ID3D10Blob_GetBufferSize(b_full), NULL, &vsf));
    CHECK(ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(b_ps), ID3D10Blob_GetBufferSize(b_ps), NULL, &ps));
    result("shader_compile", now_ms() - t_sh, "ms");

    D3D11_BUFFER_DESC cbd = {16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0};
    ID3D11Buffer *cb = NULL;
    CHECK(ID3D11Device_CreateBuffer(dev, &cbd, NULL, &cb));

    D3D11_RASTERIZER_DESC rd = {0};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    ID3D11RasterizerState *rs = NULL;
    CHECK(ID3D11Device_CreateRasterizerState(dev, &rd, &rs));

    D3D11_BLEND_DESC bd = {0};
    bd.RenderTarget[0].BlendEnable = TRUE;
    bd.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    ID3D11BlendState *blend = NULL;
    CHECK(ID3D11Device_CreateBlendState(dev, &bd, &blend));

    unsigned total = (unsigned)draws * (unsigned)inst;
    unsigned cols = 1;
    while ((double)cols * cols * 9 < (double)total * 16) cols++;
    unsigned rows = (total + cols - 1) / cols;
    float size = 0.45f * 2.0f / (float)cols;

    g.vp = (D3D11_VIEWPORT){0, 0, (float)W, (float)H, 0, 1};
    g.ctx = ctx; g.sc = sc; g.rtv = rtv; g.rs = rs; g.vs = vs; g.vsf = vsf; g.ps = ps; g.cb = cb; g.blend = blend;
    g.draws = draws; g.inst = inst; g.overdraw = overdraw; g.cols = cols; g.rows = rows; g.size = size;
    D3D11_QUERY_DESC qd = {D3D11_QUERY_EVENT, 0};
    g.depth = getenv("BENCH_INFLIGHT") ? atoi(getenv("BENCH_INFLIGHT")) : 3;
    if (g.depth < 1 || g.depth > 16) g.depth = 3;
    for (int i = 0; i < g.depth; i++) CHECK(ID3D11Device_CreateQuery(dev, &qd, &g.q[i]));

    if (!frame(1)) return 5;   /* first frame: pipelines get built here */
    result("first_frame", now_ms() - t_start, "ms");
    { double t = now_ms(); for (int i = 0; i < 2000; i++) bench_pump(); result("peekmessage", (now_ms() - t) * 1000.0 / 2000, "us/call"); }
    if (!frame_phase("present", 1, seconds, frame, bench_pump)) return 5;
    if (!frame_phase("offscreen", 0, seconds, frame, bench_pump)) return 5;
    DestroyWindow(hwnd);
    printf("d3d11: done\n");
    return 0;
}
