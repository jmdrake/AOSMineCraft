"""Stage the native window backend and build with the host MiniA2 SDK."""

import argparse
from contextlib import nullcontext
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("windows", "linux"))
    parser.add_argument("--ob", default="ob", help="Path to the MiniA2 ob compiler")
    args = parser.parse_args()
    host = platform.system().lower()
    if args.target != host or platform.machine().lower() not in ("amd64", "x86_64"):
        parser.error(
            f"GUI builds require a native {args.target} x86-64 SDK. "
            f"Run task build:{args.target} on {args.target} x86-64; "
            "the SDK does not cross-compile --gui programs."
        )
    compiler = shutil.which(args.ob)
    if compiler is None:
        parser.error("MiniA2 ob was not found. Install the native SDK with lib-gui/ and add it to PATH, or set OB=/path/to/ob.")

    root = Path(__file__).resolve().parent.parent
    output = root / "build" / args.target
    sources = output / "src"
    sources.mkdir(parents=True, exist_ok=True)
    # Copy only this build's sources: the desktop window backend must not enter the SDK build.
    for source in (
        root / "vendor" / "raytracer" / "srBase.Mod",
        root / "vendor" / "raytracer" / "srRayEngine.Mod",
        root / "srMine.Mod",
        root / "srMineRender.Mod",
        root / "standalone" / "srMineWindow.Mod",
        root / "standalone" / "srMineApp.Mod",
    ):
        shutil.copy2(source, sources / source.name)

    name = "AOSMineCraft.exe" if args.target == "windows" else "AOSMineCraft"
    executable = output / name
    # Never let an old executable turn a failed compiler invocation into a successful build.
    executable.unlink(missing_ok=True)
    # Link on the host filesystem. On WSL's Windows mounts, the SDK's chmod can
    # fail while the linker still holds the output open. Copy out after ob exits.
    linking_directory = (
        tempfile.TemporaryDirectory(prefix="aosminecraft-")
        if args.target == "linux"
        else nullcontext(str(output))
    )
    with linking_directory as temporary:
        linked = Path(temporary) / name
        result = subprocess.run(
            [compiler, "build", "--gui=720x540", "srMineApp.Mod", "-o", str(linked)],
            cwd=sources,
        )
        if result.returncode:
            return result.returncode
        if not linked.is_file():
            print("Build failed: ob did not produce the executable.", file=sys.stderr)
            return 1
        if linked != executable:
            shutil.copy2(linked, executable)
    shutil.copy2(root / "LICENSE", output / "LICENSE")
    shutil.copy2(root / "vendor" / "raytracer" / "LICENSE.txt", output / "A2-LICENSE.txt")
    shutil.copy2(root / "vendor" / "raytracer" / "README.md", output / "RAYTRACER-NOTICE.md")
    print(f"Built {executable}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
