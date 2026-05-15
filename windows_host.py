#!/usr/bin/env python3
import argparse
import ctypes
import json
import socket
import sys
import threading
import time
from ctypes import wintypes


WH_MOUSE_LL = 14
WH_KEYBOARD_LL = 13
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_RBUTTONDOWN = 0x0204
WM_RBUTTONUP = 0x0205
WM_MBUTTONDOWN = 0x0207
WM_MBUTTONUP = 0x0208
WM_MOUSEWHEEL = 0x020A
WM_MOUSEHWHEEL = 0x020E
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105

VK_BACK = 0x08
VK_TAB = 0x09
VK_RETURN = 0x0D
VK_SHIFT = 0x10
VK_CONTROL = 0x11
VK_MENU = 0x12
VK_ESCAPE = 0x1B
VK_SPACE = 0x20
VK_PRIOR = 0x21
VK_NEXT = 0x22
VK_END = 0x23
VK_HOME = 0x24
VK_LEFT = 0x25
VK_UP = 0x26
VK_RIGHT = 0x27
VK_DOWN = 0x28
VK_DELETE = 0x2E


class POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("pt", POINT),
        ("mouseData", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", wintypes.DWORD),
        ("scanCode", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


LowLevelMouseProc = ctypes.WINFUNCTYPE(
    ctypes.c_long, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
)
LowLevelKeyboardProc = ctypes.WINFUNCTYPE(
    ctypes.c_long, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
)


VK_NAMES = {
    VK_BACK: "backspace",
    VK_TAB: "tab",
    VK_RETURN: "enter",
    VK_ESCAPE: "escape",
    VK_SPACE: "space",
    VK_PRIOR: "page_up",
    VK_NEXT: "page_down",
    VK_END: "end",
    VK_HOME: "home",
    VK_LEFT: "left",
    VK_UP: "up",
    VK_RIGHT: "right",
    VK_DOWN: "down",
    VK_DELETE: "delete",
    VK_SHIFT: "shift",
    VK_CONTROL: "ctrl",
    VK_MENU: "alt",
    0xBA: ";",
    0xBB: "=",
    0xBC: ",",
    0xBD: "-",
    0xBE: ".",
    0xBF: "/",
    0xC0: "`",
    0xDB: "[",
    0xDC: "\\",
    0xDD: "]",
    0xDE: "'",
}


def key_name(vk):
    if 0x30 <= vk <= 0x39:
        return chr(vk).lower()
    if 0x41 <= vk <= 0x5A:
        return chr(vk).lower()
    return VK_NAMES.get(vk)


def high_word_signed(value):
    high = (int(value) >> 16) & 0xFFFF
    if high >= 0x8000:
        high -= 0x10000
    return high


class Host:
    def __init__(self, mac_ip, port, edge):
        if sys.platform != "win32":
            raise RuntimeError("windows_host.py must run on Windows")

        self.user32 = ctypes.windll.user32
        self.kernel32 = ctypes.windll.kernel32
        self.mac_ip = mac_ip
        self.port = port
        self.edge = edge
        self.sock = None
        self.sock_file = None
        self.remote_active = False
        self.last_pos = None
        self.ctrl = False
        self.alt = False
        self.lock = threading.Lock()
        self.screen_width = self.user32.GetSystemMetrics(0)
        self.screen_height = self.user32.GetSystemMetrics(1)
        self.mouse_proc = LowLevelMouseProc(self.mouse_hook)
        self.keyboard_proc = LowLevelKeyboardProc(self.keyboard_hook)
        self.mouse_hook_handle = None
        self.keyboard_hook_handle = None

    def connect(self):
        while True:
            try:
                sock = socket.create_connection((self.mac_ip, self.port), timeout=5)
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                self.sock = sock
                self.sock_file = sock.makefile("r", encoding="utf-8", newline="\n")
                print(f"connected to Mac at {self.mac_ip}:{self.port}", flush=True)
                threading.Thread(target=self.reader, daemon=True).start()
                return
            except OSError as exc:
                print(f"waiting for Mac client: {exc}", flush=True)
                time.sleep(2)

    def reader(self):
        while True:
            try:
                line = self.sock_file.readline()
                if not line:
                    raise OSError("Mac disconnected")
                msg = json.loads(line)
            except Exception as exc:
                print(f"connection lost: {exc}", flush=True)
                self.remote_active = False
                self.connect()
                return

            if msg.get("type") == "release":
                self.release_to_windows()

    def send(self, payload):
        try:
            self.sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        except OSError:
            pass

    def edge_reached(self, x, y):
        if self.edge == "right":
            return x >= self.screen_width - 2
        if self.edge == "left":
            return x <= 1
        if self.edge == "top":
            return y <= 1
        if self.edge == "bottom":
            return y >= self.screen_height - 2
        return False

    def pin_to_edge(self):
        x, y = POINT(), POINT()
        pt = POINT()
        self.user32.GetCursorPos(ctypes.byref(pt))
        x, y = pt.x, pt.y
        if self.edge == "right":
            x = self.screen_width - 3
        elif self.edge == "left":
            x = 2
        elif self.edge == "top":
            y = 2
        elif self.edge == "bottom":
            y = self.screen_height - 3
        self.user32.SetCursorPos(x, y)
        self.last_pos = (x, y)

    def activate_remote(self, x, y):
        if self.remote_active:
            return
        self.remote_active = True
        self.last_pos = (x, y)
        print("control moved to Mac", flush=True)
        self.pin_to_edge()

    def release_to_windows(self):
        with self.lock:
            if not self.remote_active:
                return
            self.remote_active = False
            self.last_pos = None
            print("control returned to Windows", flush=True)
            self.pin_to_edge()

    def mouse_hook(self, nCode, wParam, lParam):
        if nCode < 0:
            return self.user32.CallNextHookEx(None, nCode, wParam, lParam)

        info = ctypes.cast(lParam, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
        x, y = int(info.pt.x), int(info.pt.y)

        with self.lock:
            if not self.remote_active:
                if wParam == WM_MOUSEMOVE and self.edge_reached(x, y):
                    self.activate_remote(x, y)
                    return 1
                self.last_pos = (x, y)
                return self.user32.CallNextHookEx(None, nCode, wParam, lParam)

            if wParam == WM_MOUSEMOVE:
                if self.last_pos is None:
                    self.last_pos = (x, y)
                dx = x - self.last_pos[0]
                dy = y - self.last_pos[1]
                if dx or dy:
                    self.send({"type": "move", "dx": dx, "dy": dy})
                self.last_pos = (x, y)
                self.pin_to_edge()
            elif wParam in (WM_LBUTTONDOWN, WM_LBUTTONUP):
                self.send({"type": "button", "button": "left", "down": wParam == WM_LBUTTONDOWN})
            elif wParam in (WM_RBUTTONDOWN, WM_RBUTTONUP):
                self.send({"type": "button", "button": "right", "down": wParam == WM_RBUTTONDOWN})
            elif wParam in (WM_MBUTTONDOWN, WM_MBUTTONUP):
                self.send({"type": "button", "button": "middle", "down": wParam == WM_MBUTTONDOWN})
            elif wParam == WM_MOUSEWHEEL:
                self.send({"type": "scroll", "dx": 0, "dy": high_word_signed(info.mouseData) // 120})
            elif wParam == WM_MOUSEHWHEEL:
                self.send({"type": "scroll", "dx": high_word_signed(info.mouseData) // 120, "dy": 0})

        return 1

    def keyboard_hook(self, nCode, wParam, lParam):
        if nCode < 0:
            return self.user32.CallNextHookEx(None, nCode, wParam, lParam)

        info = ctypes.cast(lParam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
        vk = int(info.vkCode)
        down = wParam in (WM_KEYDOWN, WM_SYSKEYDOWN)
        up = wParam in (WM_KEYUP, WM_SYSKEYUP)
        if not (down or up):
            return self.user32.CallNextHookEx(None, nCode, wParam, lParam)

        if vk == VK_CONTROL:
            self.ctrl = down
        elif vk == VK_MENU:
            self.alt = down

        if down and self.ctrl and self.alt and vk == VK_BACK:
            print("emergency quit", flush=True)
            self.user32.PostQuitMessage(0)
            return 1

        with self.lock:
            if self.remote_active:
                name = key_name(vk)
                if name:
                    self.send({"type": "key", "key": name, "down": bool(down)})
                return 1

        return self.user32.CallNextHookEx(None, nCode, wParam, lParam)

    def install_hooks(self):
        self.mouse_hook_handle = self.user32.SetWindowsHookExW(
            WH_MOUSE_LL, self.mouse_proc, self.kernel32.GetModuleHandleW(None), 0
        )
        self.keyboard_hook_handle = self.user32.SetWindowsHookExW(
            WH_KEYBOARD_LL, self.keyboard_proc, self.kernel32.GetModuleHandleW(None), 0
        )
        if not self.mouse_hook_handle or not self.keyboard_hook_handle:
            raise ctypes.WinError()

    def message_loop(self):
        msg = wintypes.MSG()
        while self.user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            self.user32.TranslateMessage(ctypes.byref(msg))
            self.user32.DispatchMessageW(ctypes.byref(msg))

    def run(self):
        self.connect()
        print(f"screen detected: {self.screen_width}x{self.screen_height}", flush=True)
        print(f"move mouse to Windows {self.edge} edge to control Mac", flush=True)
        print("Ctrl + Alt + Backspace quits the host", flush=True)
        self.install_hooks()
        self.message_loop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mac-ip", required=True)
    parser.add_argument("--port", type=int, default=45877)
    parser.add_argument("--edge", choices=["left", "right", "top", "bottom"], default="right")
    args = parser.parse_args()
    Host(args.mac_ip, args.port, args.edge).run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
