#!/usr/bin/env python3
"""Mirror an RGB565 Linux framebuffer into a GTK window."""

import argparse
import os
import signal
import sys

import cairo
import gi

gi.require_foreign("cairo")
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402


class Framebuffer:
    def __init__(self, device: str):
        self.device = os.path.realpath(device)
        fb_name = os.path.basename(self.device)
        sysfs = os.path.join("/sys/class/graphics", fb_name)

        with open(os.path.join(sysfs, "virtual_size"), encoding="ascii") as handle:
            self.width, self.height = map(int, handle.read().strip().split(","))
        with open(os.path.join(sysfs, "bits_per_pixel"), encoding="ascii") as handle:
            bits_per_pixel = int(handle.read().strip())

        if bits_per_pixel != 16:
            raise RuntimeError(
                f"{device} uses {bits_per_pixel} bpp; this app requires RGB565 (16 bpp)"
            )

        stride_path = os.path.join(sysfs, "stride")
        try:
            with open(stride_path, encoding="ascii") as handle:
                self.stride = int(handle.read().strip())
        except FileNotFoundError:
            self.stride = self.width * 2

        self.frame_size = self.stride * self.height
        self.buffer = bytearray(self.frame_size)
        self.fd = os.open(self.device, os.O_RDONLY | os.O_CLOEXEC)
        self.surface = cairo.ImageSurface.create_for_data(
            self.buffer,
            cairo.FORMAT_RGB16_565,
            self.width,
            self.height,
            self.stride,
        )

    def update(self):
        data = os.pread(self.fd, self.frame_size, 0)
        if len(data) != self.frame_size:
            raise OSError(
                f"short framebuffer read: expected {self.frame_size}, got {len(data)} bytes"
            )
        if data == self.buffer:
            return False
        self.buffer[:] = data
        self.surface.mark_dirty()
        return True

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class MirrorWindow(Gtk.ApplicationWindow):
    def __init__(self, application, framebuffer, fps, start_fullscreen):
        super().__init__(application=application)
        self.framebuffer = framebuffer
        self.interval_ms = max(1, round(1000 / fps))
        self.is_fullscreen = False
        self.timer_id = None
        self.last_error = None

        self.set_title("FB Mirror")
        self.set_default_size(framebuffer.width * 3, framebuffer.height * 3)
        self.set_size_request(framebuffer.width, framebuffer.height)

        self.header = Gtk.HeaderBar()
        self.header.set_show_close_button(True)
        self.header.set_title("FB Mirror")
        self.header.set_subtitle(
            f"{framebuffer.device}  ·  {framebuffer.width} × {framebuffer.height}  ·  {fps} FPS"
        )
        self.set_titlebar(self.header)

        self.fullscreen_button = Gtk.Button()
        self.fullscreen_button.set_image(
            Gtk.Image.new_from_icon_name("view-fullscreen-symbolic", Gtk.IconSize.BUTTON)
        )
        self.fullscreen_button.set_tooltip_text("Fullscreen")
        self.fullscreen_button.connect("clicked", self.toggle_fullscreen)
        self.header.pack_end(self.fullscreen_button)

        overlay = Gtk.Overlay()
        self.area = Gtk.DrawingArea()
        self.area.set_hexpand(True)
        self.area.set_vexpand(True)
        self.area.connect("draw", self.on_draw)
        self.area.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.area.connect("button-press-event", self.on_button_press)
        overlay.add(self.area)

        self.error_label = Gtk.Label()
        self.error_label.set_halign(Gtk.Align.CENTER)
        self.error_label.set_valign(Gtk.Align.CENTER)
        self.error_label.set_line_wrap(True)
        self.error_label.set_margin_start(24)
        self.error_label.set_margin_end(24)
        self.error_label.get_style_context().add_class("error")
        self.error_label.hide()
        overlay.add_overlay(self.error_label)
        self.add(overlay)

        self.connect("key-press-event", self.on_key_press)
        self.connect("window-state-event", self.on_window_state)
        self.connect("destroy", self.on_destroy)

        try:
            framebuffer.update()
        except OSError as error:
            self.show_error(str(error))
        self.timer_id = GLib.timeout_add(self.interval_ms, self.refresh)

        self.show_all()
        self.error_label.set_visible(self.last_error is not None)
        if start_fullscreen:
            self.fullscreen()

    def refresh(self):
        try:
            changed = self.framebuffer.update()
            if self.last_error is not None:
                self.last_error = None
                self.error_label.hide()
            if changed:
                self.area.queue_draw()
        except OSError as error:
            self.show_error(str(error))
        return GLib.SOURCE_CONTINUE

    def show_error(self, message):
        if message != self.last_error:
            self.last_error = message
            self.error_label.set_text(f"Unable to read the framebuffer\n{message}")
            self.error_label.show()

    def on_draw(self, widget, cr):
        allocation = widget.get_allocation()
        cr.set_source_rgb(0.035, 0.035, 0.035)
        cr.paint()

        scale = min(
            allocation.width / self.framebuffer.width,
            allocation.height / self.framebuffer.height,
        )
        if scale >= 1:
            scale = max(1, int(scale))

        draw_width = self.framebuffer.width * scale
        draw_height = self.framebuffer.height * scale
        cr.translate(
            (allocation.width - draw_width) / 2,
            (allocation.height - draw_height) / 2,
        )
        cr.scale(scale, scale)
        cr.set_source_surface(self.framebuffer.surface, 0, 0)
        cr.get_source().set_filter(cairo.FILTER_NEAREST)
        cr.paint()
        return False

    def toggle_fullscreen(self, *_args):
        if self.is_fullscreen:
            self.unfullscreen()
        else:
            self.fullscreen()

    def on_button_press(self, _widget, event):
        if event.type == Gdk.EventType.DOUBLE_BUTTON_PRESS and event.button == 1:
            self.toggle_fullscreen()
            return True
        return False

    def on_key_press(self, _widget, event):
        if event.keyval == Gdk.KEY_F11:
            self.toggle_fullscreen()
            return True
        if event.keyval == Gdk.KEY_Escape and self.is_fullscreen:
            self.unfullscreen()
            return True
        return False

    def on_window_state(self, _widget, event):
        self.is_fullscreen = bool(event.new_window_state & Gdk.WindowState.FULLSCREEN)
        self.header.set_visible(not self.is_fullscreen)
        icon = "view-restore-symbolic" if self.is_fullscreen else "view-fullscreen-symbolic"
        self.fullscreen_button.set_image(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
        return False

    def on_destroy(self, *_args):
        if self.timer_id is not None:
            GLib.source_remove(self.timer_id)
            self.timer_id = None
        self.framebuffer.close()


class MirrorApplication(Gtk.Application):
    def __init__(self, framebuffer, fps, start_fullscreen):
        super().__init__(application_id="com.m5stack.FramebufferMirror")
        self.framebuffer = framebuffer
        self.fps = fps
        self.start_fullscreen = start_fullscreen

    def do_activate(self):
        window = self.get_active_window()
        if window is None:
            window = MirrorWindow(
                self, self.framebuffer, self.fps, self.start_fullscreen
            )
        window.present()


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="/dev/fb_lcd", help="framebuffer device")
    parser.add_argument("--fps", type=int, default=30, help="refresh rate (1-60)")
    parser.add_argument("--fullscreen", action="store_true", help="start fullscreen")
    args = parser.parse_args()
    if not 1 <= args.fps <= 60:
        parser.error("--fps must be between 1 and 60")
    return args


def main():
    args = parse_args()
    try:
        framebuffer = Framebuffer(args.device)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"framebuffer-mirror: {error}", file=sys.stderr)
        return 1

    app = MirrorApplication(framebuffer, args.fps, args.fullscreen)
    signal.signal(signal.SIGTERM, lambda *_args: app.quit())
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    raise SystemExit(main())
