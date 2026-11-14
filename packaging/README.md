# Application icon

`sun-video-editor.png` is the application artwork for the desktop launcher,
Snap package, and macOS app. The transparent square PNG depicts a golden pixel sun
with a play symbol inside a golden arcade frame, with amber scanlines and status
lights on a dark brown-black screen. Its style is inspired by the
[C++ Test Explorer icon](https://github.com/namo-robotics/test_explorer_cpp/blob/main/assets/icon.svg).

The macOS packaging script converts it to an `.icns` family with `sips` and
`iconutil`, including standard and Retina sizes. Linux packaging installs the
artwork as `sun-video-editor.png` to match the desktop launcher's icon name.
