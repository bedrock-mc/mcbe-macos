# mcbe-macos

Minecraft Bedrock on Apple Silicon Macs, using the iOS client. It runs natively: arm64 code on the CPU and Metal rendering on the GPU, with no emulator, VM or Rosetta. [PlayCover](https://github.com/PlayCover/PlayCover) runs the iOS app; this repo adds working settings and a small dylib (`libmacfix`) that fixes what PlayCover does not.

![A world at 120 Hz](docs/world.jpg)
![Playing on a server](docs/server.jpg)

Tested with Minecraft 1.26.50 on an M3 Pro, macOS 26.5.

## What it fixes

| Problem | Fix |
| --- | --- |
| Clicks or keys dead for a whole session (hover still works) | Re-runs the game's mouse and keyboard setup when a startup race skipped it, and for every connected mouse (e.g. trackpad plus USB mouse), not just the current one |
| 60 FPS cap on 120 Hz displays | Raises the game's render loop to 120 Hz |
| Battery drain | 60 FPS on battery or in Low Power Mode, 120 on AC |
| Closing the window leaves the game stuck in the background | Exits cleanly after the game has saved (its exit path otherwise deadlocks) |
| Freezes after the loading screen with a VPN (e.g. WireGuard) connected | Fails the game's per-frame lookup of the bogus host `Error` instantly instead of after macOS's 5 s timeout |
| Game uses about four CPU cores in a world | Chunk-streaming threads sleep briefly instead of spinning, which roughly halves CPU use (see [Performance](#performance)) |
| In a window, closing an in-game UI leaves the cursor visible and free to leave the window until you click | Hides and holds the cursor when the game asks for the pointer lock again (`MACFIX_CAPTURE=0` turns this off) |
| Esc (e.g. closing a UI) leaves full screen, or beeps in a window | Keeps Esc for the game; the green button and Ctrl-Cmd-F still leave it |
| Scroll wheel and trackpad scrolling do nothing | Passes the vertical scroll amount in the value the game reads |
| "Invalid key" beep on every WASD press | Silences it for keys the game reads directly |
| Game Mode stays off; crash with keymapping; black bars | Marks the app as a game; keymapping off; 1080p at 16:10 |

## Requirements

- An Apple Silicon Mac and Xcode Command Line Tools (`xcode-select --install`).
- **PlayCover nightly**, build 1620 or newer (the 3.1.0 release crashes). Get `PlayCover_nightly_*.dmg` from the [nightly runs](https://github.com/PlayCover/PlayCover/actions/workflows/2.nightly_release.yml) (GitHub sign-in needed).
- A decrypted Minecraft IPA of a version you own (PlayCover only runs decrypted apps). To check a copy against Apple's build of the same version: `python3 scripts/verify_decrypted.py apple.ipa decrypted.ipa`.

## Setup

```sh
git clone https://github.com/bedrock-mc/mcbe-macos && cd mcbe-macos
scripts/setup.sh /path/to/decrypted-minecraft.ipa
```

This installs the IPA into PlayCover, applies the settings (keymapping off, 1080p 16:10, Resolution Scaler 1.5, unlimited in-game frame rate), builds and adds `libmacfix`, and re-signs the app. Then launch Minecraft from PlayCover.

Reinstalling or updating the IPA in PlayCover removes the patch: run `scripts/setup.sh --patch-only` afterwards.

## AI agents (MCP)

`libmacfix` includes an agent server for [mcpelauncher-agent](https://github.com/bedrock-mc/mcpelauncher-agent), an MCP server that lets an AI agent play the real client: keys, mouse, chat, screenshots, `minecraft://` links, frame-rate cap. It is **headless** by default: the window stays hidden while the game keeps rendering and taking input at 10 FPS, using about a third of one CPU core, against about two cores when playing in a world at 120 FPS.

```sh
claude mcp add minecraft -e MCPELAUNCHER_BACKEND=ios -- bun run /path/to/mcpelauncher-agent/src/index.ts
```

One instance per Mac. The server is off in normal launches (`MACFIX_AGENT_PORT` enables it, `MACFIX_AGENT_HIDDEN=1` hides the window).

## Performance

The game's chunk-streaming threads spin on `sched_yield` between jobs, over two cores of mostly kernel time. `libmacfix` makes a thread that is clearly spinning sleep for 50 µs instead. It also forwards the game's per-mouse-move pointer-lock updates to UIKit only when they change.

Measured in a local world at 120 Hz on an M3 Pro, 30 s camera sweeps, 6 runs each:

| | Game CPU | Streaming threads | Main thread | FPS | Frame interval p50 / p95 |
| --- | --- | --- | --- | --- | --- |
| Without the fixes | ~410% | ~260% | ~37% | ~100 | 8.3 / 16.7 ms |
| With them | ~210% | ~67% | ~29% | ~103 | 8.3 / 16.7 ms |

To compare, or if something regresses, launch with `open --env MACFIX_YIELD=spin <app>` to restore the spinning, or `MACFIX_POINTER_LOCK=every` to forward every update. With the agent server on, `frame_stats` reports frame intervals and CPU per thread group, and `threads` the scheduling state of each thread; `scripts/setup.sh --patch-only --debuggable` lets Instruments attach.

On battery or in Low Power Mode the game runs at 60 FPS, which cut game CPU from ~124% to ~85% on the title screen. `MACFIX_BATTERY_FPS=<n>` sets that rate (`0` keeps 120) and `MACFIX_FPS=<n>` fixes the rate on AC; the agent's `fps` cap overrides both while set.

## Troubleshooting

- **Clicks or keys do nothing:** the log should show `game mouse setup: ready=1` or `repaired mouse ... ready=1`; if neither, run `scripts/setup.sh --patch-only`.
- **"Couldn't add the Keychain Item" crash:** run `scripts/setup.sh --reset-playchain`. With PlayCover's KeyCover on, always launch from PlayCover: it only decrypts the game's keychain when it launches the game itself.
- **Dips below 120 FPS:** the GPU is the limit, and its cost follows resolution. Lower the Resolution Scaler in PlayCover's settings for Minecraft: setup uses 1.5, which dips in busy scenes; 1.25 holds about 118 FPS and 1.0 a steady 120, both visibly softer. FPS counter: turn on Metal HUD there.
- **Server on the same Mac:** use `127.0.0.1`. LAN addresses need Minecraft allowed under Privacy & Security → Local Network.
- **Logs:** `log stream --predicate 'process == "minecraftpe" AND eventMessage CONTAINS "macfix"'`.

To undo everything, reinstall the IPA from PlayCover.
