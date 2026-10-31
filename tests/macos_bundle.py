"""Exercise native dependency relocation with real Mach-O fixtures on macOS."""

import importlib.util
import pathlib
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("bundle_macos", "scripts/bundle-macos.py")
BUNDLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLER)


class BundleTests(unittest.TestCase):
    """Check portability and fail-closed behavior before packaging release artifacts."""

    def test_relocated_dependency_without_original_files(self):
        """Run an rpath-linked fixture after deleting its original executable and library."""
        with tempfile.TemporaryDirectory(dir="build", prefix="bundle-test-") as temporary:
            root = pathlib.Path(temporary).resolve()
            original = root / "original"
            original.mkdir()
            library = original / "leaf.c"
            library.write_text("/** Return a known fixture value. */\nint value(void) { return 42; }\n")
            program = original / "main.c"
            program.write_text(
                "/** Read the fixture library value. */\nextern int value(void);\n"
                "/** Succeed only when the bundled library loads. */\n"
                "int main(void) { return value() == 42 ? 0 : 1; }\n"
            )
            subprocess.run([
                "clang", "-dynamiclib", str(library), "-o", str(original / "libleaf.dylib"),
                "-Wl,-install_name,@rpath/libleaf.dylib", "-Wl,-headerpad_max_install_names",
            ], check=True)
            executable = original / "fixture"
            subprocess.run([
                "clang", str(program), f"-L{original}", "-lleaf", f"-Wl,-rpath,{original}",
                "-Wl,-headerpad_max_install_names", "-o", str(executable),
            ], check=True)
            contents = root / "Staged.app" / "Contents"
            seeds = root / "seeds.tsv"
            seeds.write_text(f"{executable}\tMacOS/fixture\n")
            BUNDLER.bundle(contents, seeds, root / "inventory.tsv")
            for relative in ("Frameworks/libleaf.dylib", "MacOS/fixture"):
                subprocess.run(["codesign", "--force", "--sign", "-", str(contents / relative)], check=True)
            relocated = root / "Moved App.app"
            contents.parent.rename(relocated)
            shutil.rmtree(original)
            subprocess.run([str(relocated / "Contents/MacOS/fixture")], check=True)

    def test_conflicting_destinations(self):
        """Reject two distinct sources that would overwrite the same bundled library."""
        with tempfile.TemporaryDirectory(dir="build", prefix="bundle-test-") as temporary:
            root = pathlib.Path(temporary)
            first, second = root / "first", root / "second"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            seeds = root / "seeds.tsv"
            seeds.write_text(f"{first}\tFrameworks/same.dylib\n{second}\tFrameworks/same.dylib\n")
            with self.assertRaisesRegex(ValueError, "collision"):
                BUNDLER.bundle(root / "Contents", seeds, root / "inventory.tsv")

    def test_destination_cannot_escape_bundle(self):
        """Reject a seed manifest that attempts to copy outside Contents."""
        with tempfile.TemporaryDirectory(dir="build", prefix="bundle-test-") as temporary:
            root = pathlib.Path(temporary)
            seeds = root / "seeds.tsv"
            seeds.write_text("/usr/bin/true\t../escaped\n")
            with self.assertRaisesRegex(ValueError, "Invalid bundle path"):
                BUNDLER.bundle(root / "Contents", seeds, root / "inventory.tsv")


if __name__ == "__main__":
    pathlib.Path("build").mkdir(exist_ok=True)
    unittest.main()
