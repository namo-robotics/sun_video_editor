# sun_video_editor

![Sun Video Editor showing video preview, trim controls, and export settings](assets/sun_video_editor.png)

## Overview

Local video editing and screen capture for Ubuntu and macOS.

- **Video Editor:** trim, cut out sections, convert, and compress videos. Export
  to MP4, MOV, WebM, MKV, AVI, or animated GIF.
- **Screencast:** capture a screen, window, or selected area as a PNG screenshot
  or MP4 recording, with optional camera and microphone recording.

## Install

### macOS

Apple Silicon with macOS 26 (Tahoe) or newer.

Download the `.dmg` from the [development release](https://github.com/namo-robotics/sun_video_editor/releases/tag/dev),
open it, and drag **Sun Video Editor** to **Applications**. The app includes its
media tools and libraries; Homebrew is not required.

For an unnotarized development build you trust, macOS may require **System
Settings > Privacy & Security > Open Anyway** after the first launch attempt.

### Ubuntu

Ubuntu 26.04, x86_64:

```sh
curl -fL --output sun-video-editor-dev.deb \
  https://github.com/namo-robotics/sun_video_editor/releases/download/dev/sun-video-editor_0.1.0_amd64.deb &&
  sudo apt install ./sun-video-editor-dev.deb &&
  sun_video_editor
```

These are development releases. Installation includes the required media dependencies.

## Build from source

Use Ubuntu 26.04 (x86_64) or macOS 26+ (Apple Silicon), with the
[Sun compiler](https://github.com/namo-robotics/sun) installed. macOS also requires
Homebrew and Xcode Command Line Tools. On Ubuntu, you can use the repository's
[VS Code development container](.devcontainer/README.md), which includes the compiler.

From the repository root, install dependencies, build, test, and run:

```sh
./scripts/install-dependencies.sh
./build.sh
./build/sun_video_editor
```

On Apple Silicon macOS, build just the editor and capture helper with:

```sh
./build_macos.sh
```

Run dependency setup first on a fresh checkout. This wrapper selects
`arm64-apple-darwin` and the editor package. Use `./build.sh --test` for tests.

To create an installable package:

- **Ubuntu:** run `./build.sh --package`, then install on your desktop with
  `sudo apt install --reinstall ./build/sun-video-editor_0.1.0_amd64.deb`.
- **macOS:** run `./scripts/package-macos.sh`, then open the generated `.dmg` in
  `build/` and drag the app to Applications.

See the [development guide](docs/development.md) for setup details and build options.

### Configured build scripts

The editor entrypoint uses `scripts/generate_view.sh` followed by
`scripts/build_editor.sh`. Sun resolves its declared dependencies before running
the scripts and provides the selected target and artifact paths through the build
context. The scripts query dependency roots with `sun dependency-path` and invoke
`sun build-compile` to preserve compiler settings. Linux and macOS capture targets
use `scripts/build_capture.sh` and `scripts/build_capture_macos.sh`, respectively.

These entrypoints can be built through the standalone `sun-config.json` or an
including config. Included local providers take precedence over downloaded
packages. Use a compiler that supports the `build` script array and
entrypoint-relative resources. The editor build script also copies icons beside
the executable so direct build outputs are runnable.

### Source dependencies

Following system setup, `./scripts/install-dependencies.sh` asks Sun to resolve
the Git dependencies in `sun-config.json` and copies their license notices for
packaging. Sun builds the selected entrypoints and their prerequisites, including
GTK binding generation, in its Git cache. No manual binding generation is needed.

Each repository declares a `packages` dictionary mapping package IDs to
`entrypoints`. Use a compiler supporting this format. Repositories use SSH and
`main`; public CI setup uses HTTPS. Run `sun build --refresh-sources` to refresh
cached revisions explicitly.

`deps.repos` and `./scripts/import.sh` remain available for optional source
development. Imported checkouts do not override cached Git dependencies by
themselves; include them as `projects` in a workspace config to use local providers.
