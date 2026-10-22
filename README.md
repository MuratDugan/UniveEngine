# UniveEngine

The open game-running engine behind [UniveGame](https://github.com/MuratDugan/UniveGame), a free macOS launcher
that plays Windows games on Apple Silicon. UniveEngine decides *how* a game runs: the Wine engines, the graphics
backends (DXVK, D3DMetal, WineD3D), the environment each game gets, the store integrations (Steam, Epic, GOG,
Ubisoft, EA), saves and controllers. Free and open source under the Apache License 2.0.

UniveEngine is an independent project with its own engine builds, its own engine manifest and its own releases.
It is derived from MacadeKit (Apache License 2.0); the required notices are in [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Engines and the manifest

UniveGame downloads engines listed in [`engine/manifest.json`](engine/manifest.json), each pinned by SHA-256.
The tarballs are attached to this repository's [releases](https://github.com/MuratDugan/UniveEngine/releases)
together with **the complete corresponding source** of every LGPL/GPL component (Wine, CrossOver's Wine tree,
Wine Staging, Wine Mono, DXVK, DXMT), the build scripts and the license texts.

| Engine | What it is | Graphics |
|---|---|---|
| 1.0.1 | Wine Staging 11.18 with DXVK 1.10.3 (Gcenx's macOS builds) | DirectX 9–11 through DXVK, WineD3D |
| 2.0.2 | Wine built from CodeWeavers' CrossOver 26.3.0 source, ready for D3DMetal | DirectX 12 through Apple's D3DMetal, DXMT |

Apple's D3DMetal is never part of an engine: users copy it from their own Game Porting Toolkit download.

## Roadmap

- Build every engine in CI from pinned sources (GitHub Actions on macOS runners) instead of mirroring.
- Newer Wine, DXVK and DXMT releases, tested against the UniveGame compatibility list.

## What's here

| Folder | What it is |
|---|---|
| `Sources/UniveEngineKit/Wine` | Engines, environments ("bottles"), graphics backends, the launch environment (`WineRunner`) |
| `Sources/UniveEngineKit/Library` | Game detection, including what a game's files say about its graphics (`GraphicsProbe`) |
| `Sources/UniveEngineKit/Stores` | Steam, Epic (via Legendary), GOG, Ubisoft Connect and EA app |
| `Sources/UniveEngineKit/Engine` | Engine download and checks, D3DMetal set-up from the user's own Game Porting Toolkit |
| `Sources/UniveEngineKit/Saves`, `Playtime`, `Shortcuts` | Save backups, play time, game links |
| `Sources/unive` | `unive`, a command-line tool that runs Windows programs the way UniveGame does |
| `engine/` | How the engines are built from pinned upstream releases, and their license texts |
| `game-fixes/` | Fixes for single games that don't belong in the app (each with its own license) |

## Build and test

Needs macOS 15 and Xcode 16 or later.

```bash
swift test                     # unit tests (no Wine needed)
swift build --product unive     # the test tool, at .build/debug/unive
```

## Trying a change with `unive`

`unive` uses the engines and environments UniveGame has already set up, so open UniveGame once first.
It reads the engine's settings but never changes them.

```bash
unive engines                                       # installed engines
unive probe "/path/to/Game"                         # DirectX 12? 64-bit? what Automatic would pick
unive env --bottle gog --backend dxvk               # the exact environment Wine would get
unive run --bottle gog --backend wined3d --verbose 'C:\GOG Games\Some Game\Game.exe'
```

`run` waits for the program to exit and prints where its log is. Like the app, it won't start an environment
that is already running on a different engine; quit the game in UniveGame first. To experiment without touching
your real environments, point `UNIVE_HOME` at another folder.

Steam games usually need Steam running in the same environment, so for those run `steam.exe` with
`-applaunch <app id>`, or start Steam from UniveGame and test from there.

## Building an engine

```bash
engine/build-engine.sh 1.0.0             # Wine Staging + DXVK (DirectX 9 to 11)
engine/build-engine-d3dmetal.sh 2.0.0    # Wine from CodeWeavers' CrossOver source, ready for D3DMetal
```

Every download is pinned by SHA-256. The output goes to `engine/dist` with a manifest; to use it, point UniveGame at the
manifest with `MACADE_ENGINE_MANIFEST=file:///…/engine-manifest.json`. Needs `brew install mingw-w64` (and, for
the CrossOver build, `bison pkgconf freetype gnutls sdl2`).

**Apple's D3DMetal is never part of this repository or of any engine built from it.** Its license only allows
redistribution for non-commercial use, and DirectX 12 support in UniveGame is offered as advanced and at the user's own
risk. UniveGame copies D3DMetal from the user's own download of Apple's Game Porting Toolkit. Don't add D3DMetal files,
or anything else from Apple's toolkit, to a pull request.

## Contributing

- Keep changes small and focused, with a test where the logic can be tested without Wine (most of it can: see
  `Tests/`). Say which game you tested with and on which Mac.
- Nothing that sends data anywhere new, and no new downloads without a pinned SHA-256.
- By sending a pull request you agree that your contribution is licensed under the Apache License 2.0, the same
  as this repository.

## License

Apache License 2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)), except where a folder has its own LICENSE file
(for example `game-fixes/witcher3`, MIT). The engines are made of third-party software under their own licenses,
listed in `engine/licenses`. "MaPC" is a trademark of Steale LLC; the license doesn't grant use of the name or logo.
