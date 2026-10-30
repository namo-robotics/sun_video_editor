"""Bridge desktop portal sessions and PipeWire streams to local capture files.

Sun owns the interface and child lifetime. This helper owns the D-Bus connection,
received Unix file descriptor, and GStreamer callbacks until capture ends.
"""

import ctypes
import math
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import uuid

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst


def selected_rectangle(start, end, scale, width, height):
    """Map a clamped drag into a bounded rectangle."""
    left = max(0, min(width, math.floor(min(start[0], end[0]) * scale)))
    top = max(0, min(height, math.floor(min(start[1], end[1]) * scale)))
    right = max(0, min(width, math.ceil(max(start[0], end[0]) * scale)))
    bottom = max(0, min(height, math.ceil(max(start[1], end[1]) * scale)))
    if right <= left or bottom <= top:
        raise ValueError("Drag a rectangle with a nonzero width and height.")
    return left, top, right - left, bottom - top


class XRectangle(ctypes.Structure):
    """Describe a rectangle for the X11 Shape extension's bounding region."""

    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                ("width", ctypes.c_ushort), ("height", ctypes.c_ushort)]


class XWindowAttributes(ctypes.Structure):
    """Match XSetWindowAttributes for an unmanaged outline with no retained resize contents."""

    _fields_ = [("background_pixmap", ctypes.c_ulong), ("background_pixel", ctypes.c_ulong),
                ("border_pixmap", ctypes.c_ulong), ("border_pixel", ctypes.c_ulong),
                ("bit_gravity", ctypes.c_int), ("win_gravity", ctypes.c_int),
                ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int),
                ("event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("colormap", ctypes.c_ulong),
                ("cursor", ctypes.c_ulong)]


class SelectionOutline:
    """Own and update one hollow native window without Tk wrappers or opacity."""

    def __init__(self):
        """Create an unmapped input-transparent outline with all operations on one connection."""
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.shape = ctypes.CDLL("libXext.so.6")
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x11.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
        self.x11.XCreateSimpleWindow.restype = ctypes.c_ulong
        self.x11.XChangeWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.POINTER(XWindowAttributes)]
        self.x11.XMoveResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
        for name in ("XDestroyWindow", "XUnmapWindow", "XClearWindow", "XMapRaised"):
            getattr(self.x11, name).argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        for name in ("XGrabServer", "XUngrabServer"):
            getattr(self.x11, name).argtypes = [ctypes.c_void_p]
        self.shape.XShapeQueryExtension.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
        self.shape.XShapeCombineRectangles.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.POINTER(XRectangle), ctypes.c_int, ctypes.c_int, ctypes.c_int]
        self.display = self.x11.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("Cannot connect to the display for screen selection.")
        event, error = ctypes.c_int(), ctypes.c_int()
        if not self.shape.XShapeQueryExtension(self.display, ctypes.byref(event), ctypes.byref(error)):
            self.x11.XCloseDisplay(self.display)
            self.display = None
            raise RuntimeError("The display does not support a hollow selection outline.")
        root = self.x11.XDefaultRootWindow(self.display)
        self.window = self.x11.XCreateSimpleWindow(self.display, root, 0, 0, 1, 1, 0, 0, 0x73e2cb)
        attributes = XWindowAttributes()
        attributes.override_redirect = 1
        attributes.bit_gravity = 0
        self.x11.XChangeWindowAttributes(self.display, self.window, (1 << 9) | (1 << 4), ctypes.byref(attributes))
        # Pointer events belong to the Tk input grab, never to this separate connection.
        self.shape.XShapeCombineRectangles(self.display, self.window, 2, 0, 0, None, 0, 0, 0)
        self.set_shape([])
        self.x11.XSync(self.display, 0)

    def set_shape(self, rectangles):
        """Replace the complete visible region, leaving no filled interior or old edge fragments."""
        region = (XRectangle * len(rectangles))(*(XRectangle(*rectangle) for rectangle in rectangles))
        self.shape.XShapeCombineRectangles(self.display, self.window, 0, 0, 0, region, len(rectangles), 0, 0)

    def hide(self):
        """Unmap the outline without changing the input grab or desktop contents."""
        self.x11.XUnmapWindow(self.display, self.window)
        self.x11.XSync(self.display, 0)

    def show(self, left, top, width, height):
        """Resize, replace the hollow shape, and repaint as one serialized server update."""
        if not (0 < width <= 32767 and 0 < height <= 32767):
            raise ValueError("Selection exceeds the supported display size.")
        thickness = min(3, width, height)
        self.x11.XGrabServer(self.display)
        try:
            self.x11.XMoveResizeWindow(self.display, self.window, left, top, width, height)
            self.set_shape([(0, 0, width, thickness),
                            (0, height - thickness, width, thickness),
                            (0, 0, thickness, height),
                            (width - thickness, 0, thickness, height)])
            self.x11.XClearWindow(self.display, self.window)
            self.x11.XMapRaised(self.display, self.window)
        finally:
            self.x11.XUngrabServer(self.display)
            self.x11.XSync(self.display, 0)

    def close(self):
        """Destroy the owned native window and close its connection."""
        if self.display:
            self.x11.XDestroyWindow(self.display, self.window)
            self.x11.XCloseDisplay(self.display)
            self.display = None


class AreaSelector:
    """Select on the live desktop with an input grab and a hollow outline window."""

    def __init__(self, width, height, position, confirm, cancel):
        """Show a small instruction bar and grab input without covering the desktop."""
        import tkinter as tk
        self.width, self.height = width, height
        self.confirm_callback, self.cancel_callback = confirm, cancel
        self.start = None
        self.end = None
        self.position = position
        self.outline = None
        self.root = tk.Tk()
        self.root.withdraw()
        x, y = position
        if width <= 0 or height <= 0 or x < 0 or y < 0 or x + width > self.root.winfo_screenwidth() or y + height > self.root.winfo_screenheight():
            self.root.destroy()
            raise ValueError("The shared screen cannot be positioned for live selection. Check your display layout.")
        self.root.title("Select capture area")
        self.root.overrideredirect(True)
        bar_width, bar_height = min(width, 480), min(height, 36)
        self.root.geometry(f"{bar_width}x{bar_height}+{x + (width - bar_width) // 2}+{y}")
        self.root.attributes("-topmost", True)
        self.root.configure(background="#152135", cursor="crosshair")
        self.root.bind_all("<Escape>", self.cancel)
        self.root.bind_all("<Return>", self.confirm)
        self.root.bind_all("<ButtonPress-1>", self.begin)
        self.root.bind_all("<B1-Motion>", self.drag)
        self.root.bind_all("<ButtonRelease-1>", self.release)
        self.root.protocol("WM_DELETE_WINDOW", self.cancel)
        tk.Label(self.root, text="Drag to select · Release to confirm · Esc to cancel",
                 background="#152135", foreground="white", cursor="crosshair").pack(fill="both", expand=True)
        try:
            self.outline = SelectionOutline()
        except Exception:
            self.root.destroy()
            raise
        self.root.deiconify()
        self.root.lift()
        self.root.wait_visibility()
        self.root.focus_force()
        try:
            self.root.grab_set_global()
        except tk.TclError:
            self.outline.close()
            self.root.destroy()
            raise RuntimeError("Cannot grab the pointer for screen selection. Close other dialogs and retry.")

    def point(self, event):
        """Translate desktop pointer coordinates into the authorized screen's coordinates."""
        return event.x_root - self.position[0], event.y_root - self.position[1]

    def begin(self, event):
        """Start a rectangle only when the pointer is on the authorized live screen."""
        x, y = self.point(event)
        if not (0 <= x < self.width and 0 <= y < self.height):
            return
        self.start = (x, y)
        self.end = self.start
        self.outline.hide()

    def drag(self, event):
        """Move and resize all four edges together, leaving the interior uncovered."""
        if self.start is None:
            return
        x, y = self.point(event)
        self.end = (max(0, min(self.width, x)), max(0, min(self.height, y)))
        try:
            left, top, width, height = selected_rectangle(self.start, self.end, 1, self.width, self.height)
        except ValueError:
            return
        left += self.position[0]
        top += self.position[1]
        self.outline.show(left, top, width, height)

    def release(self, event):
        """Confirm the rectangle when the user finishes dragging."""
        self.drag(event)
        self.confirm()

    def confirm(self, event=None):
        """Return a valid screen-coordinate rectangle without taking a screenshot."""
        if self.start is None or self.end is None:
            return
        try:
            rectangle = selected_rectangle(self.start, self.end, 1, self.width, self.height)
        except ValueError:
            return
        self.confirm_callback(rectangle)

    def cancel(self, event=None):
        """Release selection without starting capture."""
        self.cancel_callback()

    def close(self):
        """Release the input grab and remove the instruction bar and outline."""
        self.root.grab_release()
        self.outline.close()
        self.root.destroy()


class Capture:
    """Keep permission, countdown, encoding, and output publication in one lifetime."""

    def __init__(self, kind, source, delay, cursor):
        """Initialize a capture without requesting permission or creating output."""
        self.kind = kind
        self.source = source
        self.delay = delay
        self.cursor = cursor
        self.loop = GLib.MainLoop()
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.session = None
        self.request_path = None
        self.pipeline = None
        self.remote_fd = None
        self.output_fd = None
        self.temporary = None
        self.destination = None
        self.completed = False
        self.exit_code = 0
        self.deadline = None
        self.last_seconds = None
        self.recording = False
        self.finishing = False
        self.timers = []
        self.subscriptions = []
        self.selector = None
        self.region = None
        self.source_size = None
        self.capture_size = None

    def request(self, method, signature, args, options, callback):
        """Subscribe before calling a portal method so immediate responses cannot race."""
        token = "sun_" + uuid.uuid4().hex
        sender = self.bus.get_unique_name()[1:].replace(".", "_")
        path = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
        self.request_path = path
        options["handle_token"] = GLib.Variant("s", token)

        def response(connection, sender_name, object_path, interface, name, parameters):
            """Advance one portal request or close cleanly on denial or cancellation."""
            connection.signal_unsubscribe(subscription)
            self.subscriptions.remove(subscription)
            self.request_path = None
            code, results = parameters.unpack()
            if code:
                self.cancel() if code == 1 else self.fail("Desktop capture request failed.")
                return
            try:
                callback(results)
            except Exception as error:
                self.fail(str(error))

        subscription = self.bus.signal_subscribe(
            "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
            "Response", path, None, Gio.DBusSignalFlags.NONE, response,
        )
        self.subscriptions.append(subscription)
        self.bus.call_sync(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast", method,
            GLib.Variant(signature, (*args, options)), GLib.VariantType.new("(o)"),
            Gio.DBusCallFlags.NONE, 10000, None,
        )

    def create(self):
        """Request a session so source selection finishes before the capture countdown."""
        self.request("CreateSession", "(a{sv})", (), {
            "session_handle_token": GLib.Variant("s", "sun_" + uuid.uuid4().hex),
        }, self.select)

    def select(self, result):
        """Restrict the chooser to a single monitor or window and the requested pointer mode."""
        self.session = result["session_handle"]
        self.subscriptions.append(self.bus.signal_subscribe(
            "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Session", "Closed",
            self.session, None, Gio.DBusSignalFlags.NONE, self.session_closed,
        ))
        self.request("SelectSources", "(oa{sv})", (self.session,), {
            "types": GLib.Variant("u", 2 if self.source == "window" else 1),
            "multiple": GLib.Variant("b", False),
            "cursor_mode": GLib.Variant("u", 2 if self.cursor else 1),
        }, self.choose)

    def choose(self, result):
        """Open the system source permission dialog before starting the countdown."""
        self.request("Start", "(osa{sv})", (self.session, ""), {}, self.selected)

    def selected(self, result):
        """Retain the authorized stream and start a monotonic countdown."""
        streams = result.get("streams", [])
        if len(streams) != 1:
            raise RuntimeError("The desktop did not provide one capture source.")
        self.node, self.properties = streams[0]
        if self.source == "area":
            self.start_selection()
        else:
            self.begin_countdown()

    def open_remote(self):
        """Acquire a fresh PipeWire connection for one pipeline within the authorized session."""
        reply, descriptors = self.bus.call_with_unix_fd_list_sync(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.ScreenCast", "OpenPipeWireRemote",
            GLib.Variant("(oa{sv})", (self.session, {})), GLib.VariantType.new("(h)"),
            Gio.DBusCallFlags.NONE, 10000, None, None,
        )
        self.remote_fd = descriptors.get(reply.unpack()[0])

    def configure_source(self, pipeline):
        """Connect a pipeline only to the stream authorized by the desktop portal."""
        source = pipeline.get_by_name("source")
        source.set_property("fd", self.remote_fd)
        serial = self.properties.get("pipewire-serial")
        if serial is not None and source.find_property("target-object"):
            source.set_property("target-object", str(serial))
        else:
            source.set_property("path", str(self.node))

    def start_selection(self):
        """Start live selection using portal geometry before connecting to any video stream."""
        position = self.properties.get("position")
        size = self.properties.get("size")
        if position is None or size is None or len(position) != 2 or len(size) != 2:
            raise RuntimeError("This desktop does not provide screen geometry for live selection.")
        self.source_size = tuple(size)
        print("Drag a rectangle on the screen. Release to confirm; Esc to cancel.", flush=True)
        self.selector = AreaSelector(*self.source_size, position, self.area_selected, self.cancel)
        self.timers.append(GLib.timeout_add(16, self.selector_tick))

    def selector_tick(self):
        """Pump the selection window while cancellation and portal signals remain responsive."""
        if self.selector is None:
            return GLib.SOURCE_REMOVE
        try:
            self.selector.root.update()
        except Exception as error:
            self.fail(str(error))
            return GLib.SOURCE_REMOVE
        return GLib.SOURCE_CONTINUE if self.selector else GLib.SOURCE_REMOVE

    def area_selected(self, rectangle):
        """Retain the screen rectangle and remove the live overlay before counting down."""
        self.region = rectangle
        self.selector.close()
        self.selector = None
        self.begin_countdown()

    def begin_countdown(self):
        """Start the delay only after all source and region choices are confirmed."""
        self.deadline = time.monotonic() + self.delay
        self.timers.append(GLib.timeout_add(100, self.countdown))

    def countdown(self):
        """Keep the desktop responsive and do not sample frames before the delay expires."""
        seconds = max(0, int(self.deadline - time.monotonic() + 0.999))
        if seconds != self.last_seconds:
            print(f"Capture starts in {seconds} seconds…", flush=True)
            self.last_seconds = seconds
        if time.monotonic() < self.deadline:
            return GLib.SOURCE_CONTINUE
        try:
            self.start_pipeline()
        except Exception as error:
            self.fail(str(error))
        return GLib.SOURCE_REMOVE

    def prepare_output(self):
        """Reserve a private file beside a unique destination in the configured media folder."""
        directory_type = GLib.UserDirectory.DIRECTORY_PICTURES if self.kind == "screenshot" else GLib.UserDirectory.DIRECTORY_VIDEOS
        directory = Path(GLib.get_user_special_dir(directory_type) or str(Path.home()))
        directory /= "Screenshots" if self.kind == "screenshot" else "Screencasts"
        directory.mkdir(parents=True, exist_ok=True)
        extension = ".png" if self.kind == "screenshot" else ".webm"
        stamp = time.strftime("%Y-%m-%d %H-%M-%S")
        self.destination = directory / f"{'Screenshot' if self.kind == 'screenshot' else 'Screencast'} {stamp}-{uuid.uuid4().hex[:8]}{extension}"
        self.output_fd, self.temporary = tempfile.mkstemp(prefix=".sun-capture-", dir=directory)

    def start_pipeline(self, test_source=False):
        """Encode the authorized source into a private file, using bounded encoder threads."""
        if self.source == "area" and self.region is None:
            raise ValueError("Select an area before starting capture.")
        self.prepare_output()
        source = "videotestsrc is-live=true name=source" if test_source else "pipewiresrc name=source do-timestamp=true keepalive-time=100 resend-last=true"
        encoding = "pngenc snapshot=true" if self.kind == "screenshot" else f"videorate drop-only=true max-rate=30 skip-to-first=true ! vp8enc name=encoder deadline=1 lag-in-frames=0 cpu-used=4 end-usage=cq cq-level=10 max-quantizer=24 threads={max(1, min(4, (os.cpu_count() or 1) // 2))} ! webmmux"
        crop = "videoconvert ! video/x-raw,format=RGB ! videocrop name=region ! " if self.region else ""
        self.pipeline = Gst.parse_launch(f"{source} ! queue name=capture_queue ! {crop}videoconvert ! {encoding} ! fdsink name=output")
        if self.kind == "record":
            self.pipeline.get_by_name("encoder").get_static_pad("sink").add_probe(Gst.PadProbeType.EVENT_DOWNSTREAM, self.recording_caps)
        if self.region:
            self.pipeline.get_by_name("region").get_static_pad("sink").add_probe(Gst.PadProbeType.EVENT_DOWNSTREAM, self.crop_caps)
        self.pipeline.get_by_name("output").set_property("fd", self.output_fd)
        if not test_source:
            if self.remote_fd is None:
                self.open_remote()
            self.configure_source(self.pipeline)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self.message)
        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("Cannot start the capture encoder.")
        self.timers.append(GLib.timeout_add_seconds(15, self.start_timeout))

    def recording_caps(self, pad, probe):
        """Budget recording bitrate from actual pixel dimensions, including cropped sources."""
        event = probe.get_event()
        if event.type == Gst.EventType.CAPS:
            caps = event.parse_caps().get_structure(0)
            width, height = caps.get_value("width"), caps.get_value("height")
            # Use the capture frame-rate ceiling even when a still desktop advertises zero fps.
            bitrate = max(2_000_000, min(120_000_000, width * height * 30 // 4))
            self.pipeline.get_by_name("encoder").set_property("target-bitrate", bitrate)
        return Gst.PadProbeReturn.OK

    def crop_caps(self, pad, probe):
        """Map logical screen coordinates to stream pixels before any frame reaches the encoder."""
        event = probe.get_event()
        if event.type != Gst.EventType.CAPS:
            return Gst.PadProbeReturn.OK
        try:
            caps = event.parse_caps().get_structure(0)
            width, height = caps.get_value("width"), caps.get_value("height")
            if self.capture_size is not None and self.capture_size != (width, height):
                raise ValueError("The screen size changed during capture. Select the area again.")
            self.capture_size = (width, height)
            logical_width, logical_height = self.source_size
            x, y, region_width, region_height = self.region
            if logical_width <= 0 or logical_height <= 0 or x < 0 or y < 0 or region_width <= 0 or region_height <= 0 or x + region_width > logical_width or y + region_height > logical_height:
                raise ValueError("The selected area is outside the shared screen.")
            left = math.floor(x * width / logical_width)
            top = math.floor(y * height / logical_height)
            right = width - math.ceil((x + region_width) * width / logical_width)
            bottom = height - math.ceil((y + region_height) * height / logical_height)
            crop = self.pipeline.get_by_name("region")
            crop.set_property("left", left)
            crop.set_property("top", top)
            crop.set_property("right", right)
            crop.set_property("bottom", bottom)
        except Exception as error:
            GLib.idle_add(self.fail, str(error))
            return Gst.PadProbeReturn.DROP
        return Gst.PadProbeReturn.OK

    def start_timeout(self):
        """Bound startup when the desktop stream never produces usable frames."""
        if not self.completed and (self.kind == "screenshot" or not self.recording):
            self.fail("The desktop did not produce a capture frame.")
        return GLib.SOURCE_REMOVE

    def message(self, bus, message):
        """Report live state, finalize on end of stream, and surface encoder failures."""
        if message.type == Gst.MessageType.ERROR:
            error, detail = message.parse_error()
            # A revoked PipeWire node can report failure before the portal's Closed signal.
            if self.kind == "record" and self.recording and message.src == self.pipeline.get_by_name("source"):
                self.stop()
            else:
                self.fail(error.message)
        elif message.type == Gst.MessageType.STATE_CHANGED and message.src == self.pipeline:
            old, new, pending = message.parse_state_changed()
            if new == Gst.State.PLAYING:
                self.recording = True
                print("Recording…" if self.kind == "record" else "Taking screenshot…", flush=True)
        elif message.type == Gst.MessageType.EOS:
            self.pipeline.set_state(Gst.State.NULL)
            try:
                self.publish()
            except OSError as error:
                self.fail(str(error))
            self.loop.quit()

    def publish(self):
        """Flush and publish completed output without replacing existing files."""
        os.fsync(self.output_fd)
        os.close(self.output_fd)
        self.output_fd = None
        os.link(self.temporary, self.destination)
        os.unlink(self.temporary)
        self.temporary = None
        self.completed = True
        print(f"Saved: {self.destination}", flush=True)

    def stop(self):
        """Flush a live recording; an interrupt before recording cancels instead."""
        if self.pipeline and self.recording and self.kind == "record" and not self.finishing:
            self.finishing = True
            # Drain downstream of the source: a revoked PipeWire node may no longer accept EOS.
            self.pipeline.get_by_name("capture_queue").get_static_pad("sink").send_event(Gst.Event.new_eos())
            self.timers.append(GLib.timeout_add_seconds(10, self.finish_timeout))
        elif not self.finishing:
            self.cancel()
        return GLib.SOURCE_REMOVE

    def finish_timeout(self):
        """Discard incomplete output if the encoder cannot finalize in time."""
        if not self.completed:
            self.fail("The recording could not finish saving.")
        return GLib.SOURCE_REMOVE

    def cancel(self):
        """Cancel the pending request or discard unfinished output."""
        print("Capture cancelled.", flush=True)
        self.loop.quit()
        return GLib.SOURCE_REMOVE

    def session_closed(self, *args):
        """Stop saving when the desktop revokes a live capture session."""
        self.session = None
        if self.recording and self.kind == "record":
            self.stop()
        elif not self.completed:
            self.fail("Desktop sharing ended before capture completed.")

    def fail(self, message):
        """Publish an actionable failure and let the common cleanup release resources."""
        self.exit_code = 1
        print(f"Capture failed: {message}", flush=True)
        print(message, file=sys.stderr, flush=True)
        self.loop.quit()

    def close(self):
        """Release native objects and remove only this capture's unfinished output."""
        if self.selector is not None:
            self.selector.close()
            self.selector = None
        for timer in self.timers:
            if GLib.MainContext.default().find_source_by_id(timer):
                GLib.source_remove(timer)
        for subscription in self.subscriptions:
            self.bus.signal_unsubscribe(subscription)
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline.get_bus().remove_signal_watch()
        for path, interface in ((self.request_path, "Request"), (self.session, "Session")):
            if path:
                try:
                    self.bus.call_sync("org.freedesktop.portal.Desktop", path,
                                       "org.freedesktop.portal." + interface, "Close", None,
                                       None, Gio.DBusCallFlags.NONE, 1000, None)
                except GLib.Error:
                    pass
        for descriptor in (self.output_fd, self.remote_fd):
            if descriptor is not None:
                os.close(descriptor)
        if self.temporary:
            Path(self.temporary).unlink(missing_ok=True)


def main():
    """Validate the private protocol, run the capture, and always release its session."""
    if len(sys.argv) != 5 or sys.argv[1] not in ("screenshot", "record") or sys.argv[2] not in ("screen", "window", "area") or not sys.argv[3].isdigit() or not 0 <= int(sys.argv[3]) <= 3600 or sys.argv[4] not in ("cursor", "hidden"):
        raise ValueError("Invalid capture arguments")
    Gst.init(None)
    capture = Capture(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "cursor")
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, capture.stop)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, capture.cancel)
    try:
        capture.create()
        capture.loop.run()
    finally:
        capture.close()
    return capture.exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Capture failed: {error}", flush=True)
        print(error, file=sys.stderr)
        sys.exit(1)
