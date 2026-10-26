# AOSMineCraft
Active Oberon Minecraft Demo

## Standalone Windows and Linux builds

Requirements:

- [Task](https://taskfile.dev/docs/installation), version 3.
- Python 3.8 or later (`python` on Windows, `python3` on Linux).
- The native x86-64 [MiniA2 SDK](https://github.com/active-oberon/minia2/releases)
  with `ob` on `PATH` and a `lib-gui/` directory supporting `ob build --gui`.
  Older headless SDKs cannot build this game.

Build for the current machine:

```sh
task build
task run
```

Or select the platform explicitly:

| Command | Build host | Executable |
| --- | --- | --- |
| `task build:windows` | Windows x86-64 | `build/windows/AOSMineCraft.exe` |
| `task build:linux` | Linux x86-64 | `build/linux/AOSMineCraft` |

These are native GUI builds: run each task on its corresponding OS. MiniA2's
`--gui` uses the host SDK's display driver and does not support cross-compilation.
On Windows, a Linux build can be made inside WSL with a Linux SDK and Task installed:

```sh
wsl -d Ubuntu-24.04 -- sh -lc 'cd /mnt/i/Projects/OS/A2/AOSMineCraft && task build:linux'
```

Use the path to your checkout in the WSL command. Linux builds require glibc;
running the game also requires X11 (WSLg works) and `libX11.so.6`.
The resulting program contains the A2 runtime and opens a 720 x 540 game window;
players do not need a separate A2 installation or Python. Keep the license and
notice files alongside the executable when distributing it.

Override the compiler or Python executable when needed (quote paths containing spaces):

```sh
task build OB=/path/to/a2sdk/ob PYTHON=python3
```

`scripts/build.py` stages the shared game sources, bundled raytracer modules and
the standalone window backend in `build/<platform>/src/` before calling `ob`.
The staged sources and final files stay under `build/`. On Linux, linking uses
the native temporary directory before copying the executable to `build/linux/`;
this also supports checkouts on Windows disks mounted in WSL.

Controls: WASD to move, left-drag to look, Space to jump, F to fly, right click/X
to break, middle click/E to place, B/mouse wheel to select a block, Q/Escape to quit.
See [srMineReadMe.Text](srMineReadMe.Text) for the full game documentation.

## Running inside the A2 desktop

The original desktop renderer uses `srMineWindow.Mod` from the repository root.
Copy the two `vendor/raytracer/*.Mod` files into your A2 source directory if they
are not installed already, then compile and run:

```text
PC.Compile \s srBase.Mod srRayEngine.Mod srMineWindow.Mod srMine.Mod srMineRender.Mod ~
SystemTools.Free srMineRender srMine srMineWindow ~
srMineRender.Open ~
```

Do not compile `standalone/srMineWindow.Mod` into the desktop: it is the alternative
backend selected by Task for standalone builds.
