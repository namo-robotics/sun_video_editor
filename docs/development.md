# Development and release guide

A native Sun application for converting, compressing, and trimming local videos,
built on [sun_ui](https://github.com/namo-robotics/sun_ui) and
[sun_gobject](https://github.com/namo-robotics/sun_gobject).


## Development environment

Open this repository in its VS Code dev container. The Ubuntu 26.04 image includes
the Sun compiler, GTK development libraries, FFmpeg, GStreamer plugins, and the
headless test tools. The container mounts the same Codex, Claude, SSH, GitHub CLI,
and VS Code user configuration as sun_ui, with a separate editor ccache volume.
Agent instructions are provided in both `AGENTS.md` and `CLAUDE.md`.

Run from this repository's root:

```sh
./scripts/install-dependencies.sh
./build.sh
./build/sun_video_editor
```

The installer downloads published `sun_ui` and `sun_gobject` release assets into
`build/dependencies/`. Linux uses Debian packages; macOS uses Apple Silicon
archives. The `sun-ui` Debian package includes `sun-viewc`, and `sun-gobject`
includes the native archive. Both packages include license notices and compiler
version records, checked against the installed compiler before installation.
No dependency sources are imported or built; `deps.repos` is empty.

Release tags default to `dev` and can be selected with `SUN_UI_RELEASE` and
`SUN_GOBJECT_RELEASE`. Missing assets or compiler mismatches stop setup without
a source-build fallback. For an offline build, put the release assets in one
directory and run `./scripts/install-dependencies.sh --from-directory /path/to/assets`.

For incremental work:

```sh
./build.sh --build
./build.sh --test
```

The editor can also use compatible prebuilt dependency bundles through
`SUN_UI_BUILD` and `SUN_GOBJECT_BUILD`.
Packaging additionally accepts `SUN_UI_SOURCE` and `SUN_GOBJECT_SOURCE` for the
corresponding license files.

FFmpeg and ffprobe **8 or newer** are required. Startup checks their released
version numbers, H.264/AAC encoders, and the scale filter's `reset_sar` support.
Preview playback needs GTK's GStreamer backend, `gstreamer1.0-libav`, and
`gstreamer1.0-plugins-good`. Exports remain local; no upload service is used.

## Repository layout

- `src/`: application state, media workflow, process handling, and XML views.
- `src/tools/`: Sun build and packaging tools, selecting products from `sun-config.json`.
- `tests/`: generated media fixtures, workflow tests, and native GTK acceptance.
- `packaging/`, `debian/`, `snap/`: desktop assets and distribution metadata.
- `build/`: generated view source, executables, test output, and packages.

`src/sun_video_editor.view.xml` owns screen composition. The adjacent
`components.registry.xml` registers `components.view.xml`, so views use component
names directly. `theme.view.xml` owns shared colors and control defaults.
The XML compiler is provided by sun_ui; the editor does not maintain a copy.

## Packages and release

The initial release is version `0.1.0`, maintained by David Brown
<davidwbrwn@gmail.com>. The executable is `sun_video_editor`; Debian and Snap use
`sun-video-editor` because package identifiers cannot contain underscores.

On the Ubuntu 26.04 amd64 development environment:

```sh
./build.sh --package
sudo apt install ./build/sun-video-editor_0.1.0_amd64.deb
sun_video_editor
```

The package task rebuilds and tests the application before creating the Debian
archive and `build/editor-package/root` install payload. Debian dependencies
include `ffmpeg (>= 7:8.0)` (the `7:` is the distribution's version epoch),
GStreamer plugins, and automatically detected linked libraries. The Sun compiler
is only a build dependency. Other distributions must provide compatible library
versions and FFmpeg 8+; this is not a promise of compatibility with older Debian.

The Snap recipe targets `core26`, uses the GNOME extension, and stages FFmpeg and
media plugins alongside the tested payload. From this repository's root:

```sh
snapcraft
sudo snap install ./sun-video-editor_0.1.0_amd64.snap --dangerous
sudo snap connect sun-video-editor:removable-media
snap run sun-video-editor
```

Snapcraft must be installed separately. Test the confined application on a desktop,
including preview, trimming, exporting, overwrite, cancellation, and external-drive
access. Native acceptance tests do not replace confinement testing. The D-Bus slot
matches the GTK adapter's application ID. Update `debian/changelog` and
`snap/snapcraft.yaml` together when changing the release version.

Successful pushes and merges to `main` update the
[dev prerelease](https://github.com/namo-robotics/sun_video_editor/releases/tag/dev)
with the tested amd64 Debian package and compiler version. Pull requests build
and test without publishing. CI also builds a Snap from the same tested install
payload and saves it as a workflow artifact.

To enable automatic Snap Store publication to `edge`, register the package and
export credentials restricted to this snap and channel:

```sh
snapcraft login
snapcraft register sun-video-editor
mkdir -p tmp
snapcraft export-login --snaps=sun-video-editor --channels=edge \
  --acls=package_access,package_push,package_update,package_release \
  tmp/snap-store-credentials
```

Add the exported file's contents as the repository Actions secret
`SNAPCRAFT_STORE_CREDENTIALS` in
[repository settings](https://github.com/namo-robotics/sun_video_editor/settings/secrets/actions).
Delete the local credentials file after saving the secret. Never commit it or paste
it into an issue or chat. See [Canonical's authentication guide](https://snapcraft.io/docs/snapcraft-authentication/).
Without this secret, CI still builds the Snap and explicitly reports that Store
publication was skipped. With it, successful `main` builds upload to `edge`.
Registration and any required Store review must complete before publication succeeds.

Install the edge channel on a desktop and verify confined preview and export before
promoting a revision. Stable promotion uses your interactive account, because the
CI credential is limited to edge:

```sh
sudo snap install sun-video-editor --edge
snapcraft login
snapcraft release sun-video-editor REVISION stable
```

## Workflow

1. Choose **Open video…**. Selecting a file loads its preview automatically; the
   source panel shows the selected filename. You can also
   launch `./build/sun_video_editor /path/to/video.mov`.
2. Choose MP4 (widely compatible), MOV (QuickTime), WebM (web video),
   MKV (flexible container), AVI (legacy devices), or GIF (animated image). Changing the format updates
   the output extension and clears any previous overwrite confirmation.
3. Choose **Best quality**, **High quality**, **Balanced** (recommended),
   **Smaller file**, or **Smallest file**. Keep the original resolution or limit
   it to 2160, 1080, 720, or 480 pixels. Lower quality or resolution usually
   reduces file size, at the cost of detail. Resize presets fit
   within a square, preserve display proportions, and avoid upscaling ordinary
   square-pixel input. FFmpeg applies display rotation automatically.
4. Drag the mint handles on the timeline to choose the section to keep. Click
   the track to seek and use **Play selection** to preview the selected interval.
   The time fields stay synchronized and allow exact edits in seconds or
   `HH:MM:SS`, including fractional seconds. **Reset trim** restores the full clip.
5. Choose whether to keep audio and press **Export**. **Cancel export**
   stops the job.

With the timeline focused, arrow keys scrub, Shift+arrows move the start handle,
Ctrl+arrows move the end handle, and Space toggles playback. The preview stops at
the selected end; dragging a handle also seeks to that boundary. Preview failures
are reported separately and do not prevent conversion.

The interface is defined in `src/sun_video_editor.view.xml`. Panels are distinguished
by background colors, without control outlines or hover/focus background changes.
Reusable component instances declare stable keys; other static widgets use keys
generated by sun_ui's XML compiler. Dropdown option keys identify selected values.
Both panels fill the available height, with extra space going to the video
preview. Shorter windows scroll when the controls no longer fit.
GTK drives scrolling and playback directly; the application has no fixed sleep
between UI events. Timed wakeups are used only to poll active external jobs.
Styles are cached rather than reinstalled for every control-value update.

From best quality to smallest file, H.264 uses CRF 18/21/23/26/30, VP9 uses
CRF 24/28/32/36/40, and AVI MPEG-4 uses quality 2/3/5/8/12. Audio stays at
128 kbps when enabled. WebM may take longer to encode than H.264 formats. Every export re-encodes; quality presets do not guarantee a particular
file size. Completion reports the actual output size and savings, including
when the output is larger. Only the first video and first optional audio stream
are exported. Subtitles, additional tracks, chapters, and metadata preservation
are not part of the application's contract.

The source is never intentionally replaced. Existing destinations require the
**Replace existing output** checkbox. A private directory next to the destination
holds the partial export, which is published only after successful conversion.
Cancellation, errors, and normal window closure remove owned partial files and
reap the child process. A system crash or forced kill can leave a directory
named `<output>.sun-video.*`; these are not completed exports.

HDR/BT.2020 sources are rejected until color-managed conversion is implemented.
There is no batch queue, hardware encoding, or lossless trim mode. The interface reports bounded FFmpeg diagnostics for invalid or unsupported
inputs and failed encodes.

## Structure and tests

- `media.sun`: probe parsing, time validation, and argument-vector construction.
- `process.sun`: bounded pipe polling, cancellation, and child ownership.
- `job.sun`: workflow state, progress, temporary files, and output publication.
- `sun_video_editor.view.xml`: panels, preview, time fields, and export controls.
- `view.sun`: formatting and values used by the generated XML view.
- `state.sun`, `main.sun`: controlled state, range edits, and GTK event-loop integration.
- `tests/`: generated media fixtures, integration tests, and a
  headless GTK acceptance scenario. No personal videos or downloads are needed.

Application state and export logic are written in Sun. Native playback, pointer
gestures, drawing, and chooser ownership remain in `sun_gobject`; the renderer exposes operations without leaking platform handles
into the application state.

## macOS and Homebrew

The macOS workflow targets Apple Silicon, matching the Sun compiler's Homebrew
release. It builds GTK bindings natively, runs media and native acceptance tests,
and tests installation through Homebrew before publishing a commit-specific archive
to the `dev` release. Intel Macs are not covered by this workflow.

Install the tested release on Apple Silicon with macOS 26 (Tahoe) or newer:

```sh
brew install namo-robotics/sun/sun-video-editor
sun_video_editor
```

This is a command-line-launched GTK application, with Homebrew-managed media-enabled `sun-gtk4`, FFmpeg
8+, GStreamer, and GNU coreutils. The binary is ad-hoc signed; it is not a notarized,
self-contained Finder `.app`.

For local development on an Apple Silicon Mac, install the dependencies listed in
`.github/workflows/ci.yml`, run
`./scripts/install-dependencies.sh` and `./scripts/package-macos.sh`.
The package script runs the tests before archiving.

Automatic tap updates require an Actions secret named `TAP_TOKEN` with Contents
write access to `namo-robotics/homebrew-sun`, as used by the compiler repository.
Without it, CI publishes the tested archive and formula to the GitHub dev release
and reports that the tap update was skipped.

The hosted macOS display cannot fit the resize acceptance test's large window,
so that assertion remains covered by Linux CI. macOS CI runs the media tests,
preview, trim, export, cancellation, and Homebrew installation checks.
