# UniveEngine bench

Small Windows test programs and a script that runs them through `unive run`, the same `WineRunner` the app
uses (same environment, `WINEDLLOVERRIDES` and `NativeBackendDLLs.prepare`), in a throwaway UniveEngine home.
No games are needed and the app's own environments (bottles) are never touched.

## Requirements

- Xcode (for `swift build --product unive` and `clang`)
- `brew install mingw-w64` (provides `x86_64-w64-mingw32-gcc`)
- An installed engine, by default `~/Library/Application Support/UniveGame/Engines/1.1.0` (only read)

## Run

```sh
bench/run.sh --work /tmp/unive-bench               # 3 runs, 8 s per graphics phase, every test
bench/run.sh --work /tmp/unive-bench --runs 1 --seconds 3 --tests d3d11,d3d9
bench/run.sh --work /tmp/unive-bench --engine "$HOME/Library/Application Support/MaPC/Engines/1.0.0"
```

`--work` must be a new or empty folder (or one this script made, marked with `.unive-bench`). The script puts a
`UNIVE_HOME` there, links the engine in as `Engines/<version>`, creates a fresh `steam` bottle with
`wine wineboot --init` using the environment `unive env` prints, copies the programs to `C:\bench`, runs every test
`--runs` times and prints median tables. `--keep` reuses the bottle from a previous run. At the end (and on
Ctrl-C) it runs `wineserver -k` for that bottle only.

Output in the work folder: `results.tsv` (one row per test/backend/run/metric) and `logs/` (the `unive` log of
each Windows run, with Wine's, DXVK's and MoltenVK's output). `python3 -I bench/summarize.py <work>/results.tsv`
prints the tables again.

`bench/build.sh` builds the programs alone into `bench/out` (ignored build output).

## Programs (`src/`)

| program | what it measures |
|---|---|
| `cpu.exe` / `cpu-arm64` / `cpu-x86_64` | integer loop, double-precision Mandelbrot, 64 MiB memcpy bandwidth, 4M malloc/free, thread create+join, the integer loop on every core, cost of one clock read (QueryPerformanceCounter / clock_gettime). Same source for Windows and macOS: `cpu-x86_64` runs under Rosetta, so Wine vs `cpu-x86_64` isolates Wine's own cost and `cpu-x86_64` vs `cpu-arm64` is Rosetta's. |
| `files.exe` / `files-arm64` | 256 MiB sequential write (with flush) and read, 2000 x 4 KiB files: create, folder listing, read, delete. Under Wine on `C:`. |
| `d3d11.exe` | 2000 draw calls x 100 instanced triangles (constant-buffer update per draw) + 8 blended full-screen layers, 1280x720. |
| `d3d9.exe` | the same scene with Direct3D 9 fixed-function (pre-transformed vertices, `DrawPrimitive`). |

The graphics programs run two phases, each 1 s warm-up plus `--seconds` measured:

- **present**: `Present` every frame (sync interval 0 / `D3DPRESENT_INTERVAL_IMMEDIATE`): what a game sees,
  including any cap from the presentation path.
- **offscreen**: no `Present`; at most 3 frames in flight (event queries; `BENCH_INFLIGHT=n` changes it). CPU+GPU
  throughput without the presentation path.

They also print the adapter name and the loaded `d3d11.dll`/`d3d9.dll`, device-creation time, time to first
frame and the cost of one `PeekMessage` pass. Arguments: `d3d11.exe [seconds] [draws] [triangles] [layers] [width] [height]`.

Every result is a stdout line `RESULT <name> <value> <unit>`.

## Reading the results

- **dxvk banner** counts `info:  DXVK: v...` lines in the run's log: 1 means DXVK created the device.
- Backend `wined3d` only drops the `d3d11,d3d10core=n,b` override. On engines 1.0.0 and 1.1.0 Wine's builtin
  `d3d11.dll`/`d3d10core.dll` are themselves DXVK (copied over Wine's, still carrying the builtin marker), so
  Direct3D 11 runs on DXVK either way, and there is no DXVK `d3d9.dll`, so Direct3D 9 runs on WineD3D either way.
- Graphics numbers depend on the window being visible and frontmost, on power source, and on the display's refresh
  rate (DXVK's present path is held to it). Run them with nothing else busy.
