#!/usr/bin/env python3
"""Stage downloaded release artifacts in Sun's validated local package layout."""

import hashlib
import json
import pathlib
import shutil
import sys


def stage(source, target):
    """Copy a normalized release and record every file's digest and permissions."""
    root = source / "package"
    temporary = source / "package.new"
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir()
    artifacts = []

    def copy(path, destination, executable=False):
        """Copy one regular artifact and normalize its installed permissions."""
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular dependency artifact: {path}")
        output = temporary / destination
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, output)
        output.chmod(0o755 if executable else 0o644)

    for moon in sorted((source / "build").glob("*.moon")):
        destination = f"lib/{moon.name}"
        copy(moon, destination)
        artifacts.append({"name": moon.stem, "kind": "library", "path": destination})
    generator = source / "build/sun_viewc"
    if not generator.exists():
        generator = source / "build/sun-viewc"
    if generator.exists():
        copy(generator, "bin/sun_viewc", True)
        artifacts.append({"name": "sun_viewc", "kind": "binary", "path": "bin/sun_viewc"})
    native = source / "build/native"
    if native.exists():
        for path in sorted(native.rglob("*")):
            if path.is_file():
                copy(path, pathlib.Path("lib/native") / path.relative_to(native))
    for notice in ("LICENSE", "sun-version.txt"):
        path = source / notice
        if path.exists():
            copy(path, pathlib.Path("share") / source.name / notice)
    files = []
    for path in sorted(temporary.rglob("*")):
        if path.is_file():
            files.append({"path": path.relative_to(temporary).as_posix(),
                          "hash": hashlib.sha256(path.read_bytes()).hexdigest(),
                          "executable": bool(path.stat().st_mode & 0o111)})
    (temporary / "package.json").write_text(json.dumps({
        "format_version": 1, "name": source.name,
        "package_id": f"namo-robotics/{source.name}", "target": target,
        "artifacts": artifacts, "files": files}, indent=2) + "\n")
    if root.exists():
        shutil.rmtree(root)
    temporary.rename(root)


if __name__ == "__main__":
    for argument in sys.argv[2:]:
        stage(pathlib.Path(argument), sys.argv[1])
