# Builds GTK with the media backend required by Sun Video Editor's preview.
class SunGtk4 < Formula
  desc "GTK 4 with GStreamer media playback for Sun applications"
  homepage "https://gtk.org/"
  url "https://download.gnome.org/sources/gtk/4.22/gtk-4.22.4.tar.xz"
  sha256 "51bd9f60c7d23a665a556c7364c21fb2e4e282566b3e7e092455e8f910330893"
  license "LGPL-2.1-or-later"
  keg_only "includes media playback disabled in the standard GTK formula"
  depends_on :macos
  depends_on arch: :arm64
  depends_on "dart-sass" => :build
  depends_on "gobject-introspection" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => :build
  depends_on "cairo"
  depends_on "fontconfig"
  depends_on "fribidi"
  depends_on "gdk-pixbuf"
  depends_on "gettext"
  depends_on "glib"
  depends_on "graphene"
  depends_on "gstreamer"
  depends_on "harfbuzz"
  depends_on "hicolor-icon-theme"
  depends_on "jpeg-turbo"
  depends_on "libepoxy"
  depends_on "libpng"
  depends_on "librsvg"
  depends_on "libtiff"
  depends_on "pango"
  uses_from_macos "cups"

  # Keep this GTK installation isolated and enable its built-in GStreamer backend.
  def install
    inreplace "gtk/meson.build" do |s|
      s.gsub! "'sassc'", "'sass'"
      s.gsub! "'-a', '-M', '-t', 'compact'", "'--style', 'compressed'"
    end
    ENV["DESTDIR"] = "/"
    system "meson", "setup", "build", *std_meson_args,
      "-Dbuild-examples=false", "-Dbuild-tests=false", "-Dbuild-testsuite=false",
      "-Dbuild-demos=false", "-Ddocumentation=false", "-Dman-pages=false",
      "-Dintrospection=enabled", "-Dmedia-gstreamer=enabled", "-Dvulkan=disabled",
      "-Dx11-backend=false", "-Dwayland-backend=false", "-Dmacos-backend=true"
    system "meson", "compile", "-C", "build"
    system "meson", "install", "-C", "build"
  end

  # Verify the keg contains both GTK and its selected media backend configuration.
  test do
    assert_path_exists lib/"libgtk-4.1.dylib"
    assert_match "gtk4", shell_output("#{bin}/gtk4-launch --help")
  end
end
