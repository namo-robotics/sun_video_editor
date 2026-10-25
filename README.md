# sun_video_editor

Convert, compress, and trim videos locally.

![Sun Video Editor showing video preview, trim controls, and export settings](assets/sun_video_editor.png)

## Install

### macOS

Apple Silicon with macOS 26 (Tahoe) or newer. Requires [Homebrew](https://brew.sh).

```sh
brew install namo-robotics/sun/sun-video-editor
sun_video_editor
```

### Ubuntu

Ubuntu 26.04, x86_64:

```sh
curl -fL --output sun-video-editor-dev.deb \
  https://github.com/namo-robotics/sun_video_editor/releases/download/dev/sun-video-editor_0.1.0_amd64.deb &&
  sudo apt install ./sun-video-editor-dev.deb &&
  sun_video_editor
```

These are development releases. Installation includes the required FFmpeg 8+ dependencies.

[Development and release guide](docs/development.md)
