"""Exercise capture encoding and cleanup with synthetic frames, without recording a desktop."""

import ctypes
import re
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("capture_backend", "src/tools/capture.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)
backend.Gst.init(None)


class CaptureTests(unittest.TestCase):
    """Verify real encoder output, countdown timing, and cancellation cleanup."""

    def outline_geometry(self, outline):
        """Read the actual native geometry rather than a toolkit's pending layout."""
        outline.x11.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        root = ctypes.c_ulong()
        x, y = ctypes.c_int(), ctypes.c_int()
        width, height, border, depth = (ctypes.c_uint() for _ in range(4))
        self.assertTrue(outline.x11.XGetGeometry(outline.display, outline.window, ctypes.byref(root), ctypes.byref(x), ctypes.byref(y), ctypes.byref(width), ctypes.byref(height), ctypes.byref(border), ctypes.byref(depth)))
        return x.value, y.value, width.value, height.value

    def run_capture(self, kind, cancel=False, region=None, logical_size=(320, 240), stop_mode="button"):
        """Run a bounded synthetic stream in a private output directory."""
        with tempfile.TemporaryDirectory(dir="tmp") as directory:
            capture = backend.Capture(kind, "screen", 0, True)
            if region is not None:
                capture.region = region
                capture.source_size = logical_size
            with patch.object(backend.GLib, "get_user_special_dir", return_value=directory):
                capture.start_pipeline(test_source=True)
            if kind == "record":
                def finish():
                    """Exercise portal closure and source failures in either delivery order."""
                    if cancel:
                        return capture.cancel()
                    source = capture.pipeline.get_by_name("source")
                    error = backend.GLib.Error.new_literal(backend.Gst.ResourceError.quark(), "Stream disconnected", backend.Gst.ResourceError.READ)
                    message = backend.Gst.Message.new_error(source, error, "test disconnect")
                    if stop_mode == "closed":
                        capture.session_closed()
                    elif stop_mode == "error_first":
                        capture.message(None, message)
                        capture.session_closed()
                    elif stop_mode == "closed_first":
                        capture.session_closed()
                        capture.message(None, message)
                    else:
                        capture.stop()
                    return backend.GLib.SOURCE_REMOVE
                backend.GLib.timeout_add(500, finish)
            timeout = backend.GLib.timeout_add_seconds(5, capture.finish_timeout)
            try:
                capture.loop.run()
            finally:
                backend.GLib.source_remove(timeout)
                capture.close()
            self.assertEqual(capture.exit_code, 0)
            if cancel:
                self.assertFalse(capture.destination.exists())
            else:
                self.assertTrue(capture.completed)
                result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(capture.destination)], check=True, capture_output=True, text=True)
                self.assertEqual(result.stdout.strip(), "png" if kind == "screenshot" else "vp8")
                dimensions = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(capture.destination)], check=True, capture_output=True, text=True)
                expected = (region[2] * 320 // logical_size[0], region[3] * 240 // logical_size[1]) if region else (320, 240)
                self.assertEqual(dimensions.stdout.strip(), f"{expected[0]},{expected[1]}")
            self.assertEqual(list(Path(directory).rglob(".sun-capture-*")), [])

    def test_screenshot(self):
        """A single delayed-source frame is encoded as a readable PNG."""
        self.run_capture("screenshot")

    def test_recording(self):
        """Stopping writes a finalized, readable WebM video."""
        self.run_capture("record")

    def hd_capture(self, kind, width, height):
        """Compare decoded captures with a full-resolution source frame, including pixel detail."""
        with tempfile.TemporaryDirectory(dir="tmp") as directory:
            capture = backend.Capture(kind, "screen", 0, True)
            frames = []
            original = backend.Gst.parse_launch
            def high_resolution(description):
                """Supply full-resolution RGB pixels and retain the first reference frame."""
                pipeline = original(description.replace("videotestsrc is-live=true name=source", f"videotestsrc is-live=true name=source ! video/x-raw,format=RGB,width={width},height={height},framerate=30/1"))
                def remember(pad, info):
                    """Retain only the first source frame for a decoded-output comparison."""
                    buffer = info.get_buffer()
                    frames.append(buffer.extract_dup(0, buffer.get_size()))
                    return backend.Gst.PadProbeReturn.REMOVE
                reference_pad = pipeline.get_by_name("source").get_static_pad("src") if kind == "screenshot" else pipeline.get_by_name("encoder").get_static_pad("sink")
                reference_pad.add_probe(backend.Gst.PadProbeType.BUFFER, remember)
                return pipeline
            try:
                with patch.object(backend.GLib, "get_user_special_dir", return_value=directory), patch.object(backend.Gst, "parse_launch", side_effect=high_resolution):
                    capture.start_pipeline(test_source=True)
                if kind == "record":
                    capture.timers.append(backend.GLib.timeout_add(1000, capture.stop))
                capture.timers.append(backend.GLib.timeout_add_seconds(10, capture.finish_timeout))
                capture.loop.run()
                self.assertEqual(capture.exit_code, 0)
                self.assertTrue(capture.completed)
                dimensions = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(capture.destination)], check=True, capture_output=True, text=True)
                self.assertEqual(dimensions.stdout.strip(), f"{width},{height}")
                if kind == "screenshot":
                    decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", str(capture.destination), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-threads", "1", "-"], check=True, capture_output=True)
                    self.assertEqual(decoded.stdout, frames[0], "PNG changed the source pixels")
                else:
                    reference = Path(directory) / "reference.yuv"
                    self.assertEqual(len(frames[0]), width * height * 3 // 2)
                    reference.write_bytes(frames[0])
                    comparison = subprocess.run(["ffmpeg", "-v", "info", "-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", f"{width}x{height}", "-i", str(reference), "-i", str(capture.destination), "-filter_complex_threads", "1", "-lavfi", "[0:v][1:v]ssim", "-frames:v", "1", "-f", "null", "-"], check=True, capture_output=True, text=True)
                    score = float(re.search(r"All:([0-9.]+)", comparison.stderr).group(1))
                    self.assertGreater(score, 0.97, f"Full-HD recording lost detail: SSIM {score}")
            finally:
                capture.close()

    def test_full_hd_recording_quality(self):
        """A full-HD video preserves source dimensions and fine detail after decoding."""
        self.hd_capture("record", 1920, 1080)

    def test_4k_screenshot_pixels(self):
        """A 4K screenshot retains every RGB pixel without downscaling or lossy compression."""
        self.hd_capture("screenshot", 3840, 2160)

    def test_stop_sharing(self):
        """Portal Stop sharing saves the same readable recording as the app button."""
        self.run_capture("record", stop_mode="closed")

    def test_disconnect_before_portal(self):
        """A PipeWire error before Closed still drains and saves the recording."""
        self.run_capture("record", stop_mode="error_first")

    def test_disconnect_after_portal(self):
        """A late source error does not interrupt finalization after Closed."""
        self.run_capture("record", stop_mode="closed_first")

    def test_output_error(self):
        """Output failures remain errors even after recording has begun."""
        with tempfile.TemporaryDirectory(dir="tmp") as directory:
            capture = backend.Capture("record", "screen", 0, True)
            try:
                with patch.object(backend.GLib, "get_user_special_dir", return_value=directory):
                    capture.start_pipeline(test_source=True)
                capture.recording = True
                error = backend.GLib.Error.new_literal(backend.Gst.ResourceError.quark(), "Disk full", backend.Gst.ResourceError.WRITE)
                capture.message(None, backend.Gst.Message.new_error(capture.pipeline.get_by_name("output"), error, "test output failure"))
                self.assertEqual(capture.exit_code, 1)
                self.assertFalse(capture.completed)
                self.assertFalse(capture.destination.exists())
            finally:
                capture.close()
            self.assertEqual(list(Path(directory).rglob(".sun-capture-*")), [])

    def test_static_first_frame(self):
        """The first frame reaches PLAYING without waiting for another desktop change."""
        with tempfile.TemporaryDirectory(dir="tmp") as directory:
            capture = backend.Capture("record", "screen", 0, True)
            original = backend.Gst.parse_launch
            def still_source(description):
                """Model a desktop delivering one frame followed by a long idle interval."""
                pipeline = original(description)
                frames = [0]
                def first_only(pad, info):
                    """Withhold subsequent frames while preserving normal desktop caps."""
                    frames[0] += 1
                    return backend.Gst.PadProbeReturn.OK if frames[0] == 1 else backend.Gst.PadProbeReturn.DROP
                pipeline.get_by_name("source").get_static_pad("src").add_probe(backend.Gst.PadProbeType.BUFFER, first_only)
                return pipeline
            try:
                with patch.object(backend.GLib, "get_user_special_dir", return_value=directory), patch.object(backend.Gst, "parse_launch", side_effect=still_source):
                    capture.start_pipeline(test_source=True)
                deadline = time.monotonic() + 1
                while not capture.recording and time.monotonic() < deadline:
                    backend.GLib.MainContext.default().iteration(False)
                    time.sleep(0.01)
                self.assertTrue(capture.recording, "Recording waited for a second desktop frame")
            finally:
                capture.close()

    def test_cancel(self):
        """Cancellation removes partial recordings without publishing them."""
        self.run_capture("record", cancel=True)

    def test_area_screenshot(self):
        """A selected region produces a PNG with the exact requested odd dimensions."""
        self.run_capture("screenshot", region=(13, 27, 137, 91))

    def test_area_recording(self):
        """The same region crops every recorded frame before WebM encoding."""
        self.run_capture("record", region=(13, 27, 137, 91))

    def test_scaled_area(self):
        """A logical rectangle maps to physical capture pixels on a scaled display."""
        self.run_capture("screenshot", region=(10, 20, 50, 30), logical_size=(160, 120))

    def test_area_cancel(self):
        """Cancelling a region recording removes its unfinished file."""
        self.run_capture("record", cancel=True, region=(13, 27, 137, 91))

    def test_area_coordinates(self):
        """Reverse drags, coordinate scaling, and out-of-bounds pointers map to source pixels."""
        self.assertEqual(backend.selected_rectangle((100, 50), (10, 5), 2, 1920, 1080), (20, 10, 180, 90))
        self.assertEqual(backend.selected_rectangle((-10, -20), (2000, 2000), 2, 1919, 1079), (0, 0, 1919, 1079))
        with self.assertRaises(ValueError):
            backend.selected_rectangle((10, 5), (10, 50), 1, 320, 240)

    def test_live_selection(self):
        """Drag on the overlay before any PipeWire connection, frame, or output is created."""
        capture = backend.Capture("screenshot", "area", 3, True)
        capture.properties = {"position": (0, 0), "size": (320, 240)}
        try:
            with patch.object(capture, "open_remote") as connect:
                capture.start_selection()
                self.assertIsNone(capture.deadline)
                self.assertIsNone(capture.pipeline)
                self.assertIsNone(capture.temporary)
                selector = capture.selector
                selector.root.update()
                selector.root.event_generate("<ButtonPress-1>", rootx=20, rooty=30)
                selector.root.event_generate("<B1-Motion>", rootx=170, rooty=130)
                selector.root.update()
                self.assertEqual(selector.root.grab_status(), "global")
                # The desktop must stay exposed even without a compositor or opacity support.
                self.assertLessEqual(selector.root.winfo_height(), 36)
                outline = selector.outline.window
                self.assertEqual(self.outline_geometry(selector.outline), (20, 30, 150, 100))
                # Query the server shape: Tk's geometry lookup ignores shaped-window holes.
                shape = selector.outline.shape
                shape.XShapeGetRectangles.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
                shape.XShapeGetRectangles.restype = ctypes.POINTER(backend.XRectangle)
                selector.outline.x11.XFree.argtypes = [ctypes.c_void_p]
                for window in (outline,):
                    count, ordering = ctypes.c_int(), ctypes.c_int()
                    rectangles = shape.XShapeGetRectangles(selector.outline.display, window, 0, ctypes.byref(count), ctypes.byref(ordering))
                    try:
                        boxes = [(rectangles[i].x, rectangles[i].y, rectangles[i].width, rectangles[i].height) for i in range(count.value)]
                        for x, y in ((0, 50), (149, 50), (75, 0), (75, 99)):
                            self.assertTrue(any(left <= x < left + width and top <= y < top + height for left, top, width, height in boxes))
                        self.assertFalse(any(left <= 75 < left + width and top <= 50 < top + height for left, top, width, height in boxes))
                    finally:
                        selector.outline.x11.XFree(rectangles)
                selector.root.event_generate("<B1-Motion>", rootx=5, rooty=10)
                selector.root.update()
                self.assertEqual(self.outline_geometry(selector.outline), (5, 10, 15, 20))
                selector.root.event_generate("<B1-Motion>", rootx=170, rooty=130)
                selector.root.update()
                selector.root.event_generate("<ButtonRelease-1>", rootx=170, rooty=130)
                self.assertEqual(capture.region, (20, 30, 150, 100))
                self.assertIsNone(capture.selector)
                self.assertGreater(capture.deadline, time.monotonic())
                self.assertIsNone(capture.pipeline)
                connect.assert_not_called()
        finally:
            capture.close()

    def test_outline_repeated_redraw(self):
        """Repeated moves and resizes leave only four current edges over the visible desktop."""
        outline = backend.SelectionOutline()
        x11 = outline.x11
        x11.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
        x11.XGetImage.restype = ctypes.c_void_p
        x11.XGetPixel.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        x11.XGetPixel.restype = ctypes.c_ulong
        x11.XDestroyImage.argtypes = [ctypes.c_void_p]
        root = x11.XDefaultRootWindow(outline.display)
        background_color = 0x24456b
        background = x11.XCreateSimpleWindow(outline.display, root, 0, 0, 700, 500, 0, 0, background_color)
        x11.XMapRaised(outline.display, background)
        try:
            moves = [(50, 60, 200, 140), (80, 80, 300, 230), (40, 20, 500, 420), (100, 100, 80, 60)] * 8
            for left, top, width, height in moves:
                outline.show(left, top, width, height)
                image = x11.XGetImage(outline.display, root, 0, 0, 700, 500, ctypes.c_ulong(-1).value, 2)
                self.assertTrue(image)
                try:
                    points = [(x, y) for x in range(0, 700, 17) for y in range(0, 500, 17)]
                    points.extend([(left, top + height // 2), (left + width - 1, top + height // 2), (left + width // 2, top), (left + width // 2, top + height - 1)])
                    for x, y in points:
                        inside = left <= x < left + width and top <= y < top + height
                        edge = inside and (x < left + 3 or x >= left + width - 3 or y < top + 3 or y >= top + height - 3)
                        self.assertEqual(x11.XGetPixel(image, x, y), 0x73e2cb if edge else background_color, (left, top, width, height, x, y))
                finally:
                    x11.XDestroyImage(image)
        finally:
            x11.XDestroyWindow(outline.display, background)
            outline.close()

    def test_missing_screen_geometry(self):
        """Missing portal geometry cannot silently select the wrong display or capture a frame."""
        capture = backend.Capture("record", "area", 0, True)
        capture.properties = {}
        try:
            with self.assertRaises(RuntimeError):
                capture.start_selection()
            self.assertIsNone(capture.pipeline)
            self.assertIsNone(capture.deadline)
        finally:
            capture.close()

    def test_selection_cancel(self):
        """Escape or window closure cancels without starting a countdown or output."""
        capture = backend.Capture("record", "area", 3, True)
        capture.selector = backend.AreaSelector(32, 24, (0, 0), capture.area_selected, capture.cancel)
        try:
            capture.selector.cancel()
            self.assertIsNone(capture.deadline)
            self.assertIsNone(capture.region)
            self.assertIsNone(capture.temporary)
        finally:
            capture.close()

    def test_screenshot_selection_before_delay(self):
        """Screenshot permission and source selection finish before the timer starts."""
        capture = backend.Capture("screenshot", "screen", 3, True)
        try:
            with patch.object(capture, "request") as request, patch.object(capture, "start_pipeline") as start:
                capture.create()
                self.assertEqual(request.call_args.args[0], "CreateSession")
                self.assertIsNone(capture.deadline)
                capture.selected({"streams": [(42, {})]})
                self.assertGreater(capture.deadline, time.monotonic())
                self.assertTrue(capture.countdown())
                start.assert_not_called()
                capture.deadline = time.monotonic() - 1
                self.assertFalse(capture.countdown())
                start.assert_called_once()
        finally:
            capture.close()

    def test_countdown(self):
        """The capture pipeline cannot start before its monotonic deadline."""
        capture = backend.Capture("screenshot", "screen", 3, True)
        capture.deadline = time.monotonic() + 3
        try:
            with patch.object(capture, "start_pipeline") as start:
                self.assertTrue(capture.countdown())
                start.assert_not_called()
                capture.deadline = time.monotonic() - 1
                self.assertFalse(capture.countdown())
                start.assert_called_once()
        finally:
            capture.close()


if __name__ == "__main__":
    unittest.main()
