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

Ubuntu 26.04, x86_64. The repository is currently private; sign in with a GitHub account that has access.

```sh
sudo apt install gh &&
  gh auth login &&
  gh release download dev --repo namo-robotics/sun_video_editor \
    --pattern 'sun-video-editor_*_amd64.deb' \
    --output sun-video-editor-dev.deb --clobber &&
  sudo apt install ./sun-video-editor-dev.deb &&
  sun_video_editor
```

These are development releases. Installation includes the required FFmpeg 8+ dependencies.

[Development and release guide](docs/development.md)
