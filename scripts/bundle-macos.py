#!/usr/bin/env python3
"""Relocate Mach-O dependencies using Apple's tools; used only while packaging."""

import argparse
import pathlib
import shutil
import subprocess


SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def run(*arguments):
    """Run a native utility with literal arguments and surface failures immediately."""
    return subprocess.check_output(arguments, text=True).strip()


def rpaths(source):
    """Read the runtime search paths encoded in one Mach-O image."""
    active = False
    for line in run("otool", "-l", str(source)).splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            active = line == "cmd LC_RPATH"
        if active and line.startswith("path "):
            yield line[5:].rsplit(" (offset ", 1)[0]
            active = False


def resolve(name, source):
    """Resolve a dependency in its original location before any load commands change."""
    candidate = name.replace("@loader_path", str(source.parent))
    if candidate.startswith("@rpath/"):
        for directory in rpaths(source):
            directory = directory.replace("@loader_path", str(source.parent))
            expanded = pathlib.Path(candidate.replace("@rpath", directory, 1))
            if expanded.is_file():
                return expanded.resolve(strict=True)
    if candidate.startswith("@"):
        raise ValueError(f"Cannot resolve {name} from {source}")
    return pathlib.Path(candidate).resolve(strict=True)


def reference(source, target):
    """Return a loader-relative path that survives moving the application bundle."""
    return "@loader_path/" + "../" * (len(source.parts) - 1) + str(target)


def bundle(root, seeds, inventory):
    """Copy the native dependency closure, reject collisions, and remove external paths."""
    assets = {}
    destinations = {}
    queue = []

    def add(source, destination):
        """Queue a canonical source once and reject conflicting destination filenames."""
        source = source.resolve(strict=True)
        if source in assets:
            return assets[source]
        if destination in destinations:
            raise ValueError(f"Bundled library name collision: {destination}")
        assets[source] = destination
        destinations[destination] = source
        queue.append(source)
        return destination

    for line in seeds.read_text().splitlines():
        original, relative = line.split("\t")
        destination = pathlib.Path(relative)
        if destination.is_absolute() or ".." in destination.parts:
            raise ValueError(f"Invalid bundle path: {relative}")
        add(pathlib.Path(original), destination)

    # Appending to the queue visits newly discovered libraries after existing seeds.
    for source in queue:
        relative = assets[source]
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        destination.chmod(destination.stat().st_mode | 0o200)
        identifiers = run("otool", "-D", str(source)).splitlines()[1:]
        identity = identifiers[0].strip() if identifiers else None
        dependencies = run("otool", "-L", str(source)).splitlines()[1:]
        changes = []
        for line in dependencies:
            dependency = line.strip().rsplit(" (compatibility version ", 1)[0]
            if dependency == identity or dependency.startswith(SYSTEM_PREFIXES):
                continue
            original = resolve(dependency, source)
            target = add(original, pathlib.Path("Frameworks") / original.name)
            changes.extend(("-change", dependency, reference(relative, target)))
        if identity:
            changes.extend(("-id", reference(relative, relative)))
        for search in rpaths(source):
            changes.extend(("-delete_rpath", search))
        if changes:
            run("install_name_tool", *changes, str(destination))

    inventory.write_text("".join(f"{source}\t{assets[source]}\n" for source in queue))
    print(f"Bundled {len(queue)} native executables, libraries, and plugins")


def main():
    """Parse build-only inputs and relocate an app's native seed manifest."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("contents", type=pathlib.Path)
    parser.add_argument("seeds", type=pathlib.Path)
    parser.add_argument("inventory", type=pathlib.Path)
    args = parser.parse_args()
    bundle(args.contents, args.seeds, args.inventory)


if __name__ == "__main__":
    main()
