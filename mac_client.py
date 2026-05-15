#!/usr/bin/env python3
import argparse
import json
import socket
import sys
import threading
import time

import Quartz


KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
    "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
    "`": 50, "backspace": 51, "escape": 53, "cmd": 55, "shift": 56,
    "caps_lock": 57, "alt": 58, "ctrl": 59, "right_shift": 60,
    "right_alt": 61, "right_ctrl": 62, "left": 123, "right": 124,
    "down": 125, "up": 126, "delete": 117, "home": 115, "end": 119,
    "page_up": 116, "page_down": 121,
}

BUTTON_DOWN = {
    "left": Quartz.kCGEventLeftMouseDown,
    "right": Quartz.kCGEventRightMouseDown,
    "middle": Quartz.kCGEventOtherMouseDown,
}

BUTTON_UP = {
    "left": Quartz.kCGEventLeftMouseUp,
    "right": Quartz.kCGEventRightMouseUp,
    "middle": Quartz.kCGEventOtherMouseUp,
}

BUTTON_DRAG = {
    "left": Quartz.kCGEventLeftMouseDragged,
    "right": Quartz.kCGEventRightMouseDragged,
    "middle": Quartz.kCGEventOtherMouseDragged,
}


class MacInput:
    def __init__(self, return_edge, release_callback):
        self.return_edge = return_edge
        self.release_callback = release_callback
        self.lock = threading.Lock()
        self.buttons_down = set()
        self.display = Quartz.CGMainDisplayID()
        self.bounds = Quartz.CGDisplayBounds(self.display)
        self.width = int(self.bounds.size.width)
        self.height = int(self.bounds.size.height)
        self.x = self.width // 2
        self.y = self.height // 2

    def current_pos(self):
        event = Quartz.CGEventCreate(None)
        loc = Quartz.CGEventGetLocation(event)
        return int(loc.x), int(loc.y)

    def post_mouse(self, event_type, button="left"):
        event = Quartz.CGEventCreateMouseEvent(None, event_type, (self.x, self.y), 0)
        if button == "right":
            Quartz.CGEventSetIntegerValueField(event, Quartz.kCGMouseEventButtonNumber, 1)
        elif button == "middle":
            Quartz.CGEventSetIntegerValueField(event, Quartz.kCGMouseEventButtonNumber, 2)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)

    def move(self, dx, dy):
        with self.lock:
            self.x, self.y = self.current_pos()
            self.x = max(0, min(self.width - 1, self.x + int(dx)))
            self.y = max(0, min(self.height - 1, self.y + int(dy)))
            event_type = Quartz.kCGEventMouseMoved
            if self.buttons_down:
                event_type = BUTTON_DRAG.get(next(iter(self.buttons_down)), Quartz.kCGEventMouseMoved)
            self.post_mouse(event_type)

            if self.return_edge == "left" and self.x <= 0:
                self.release_callback()
            elif self.return_edge == "right" and self.x >= self.width - 1:
                self.release_callback()

    def button(self, name, down):
        with self.lock:
            self.x, self.y = self.current_pos()
            if down:
                self.buttons_down.add(name)
                self.post_mouse(BUTTON_DOWN.get(name, Quartz.kCGEventLeftMouseDown), name)
            else:
                self.buttons_down.discard(name)
                self.post_mouse(BUTTON_UP.get(name, Quartz.kCGEventLeftMouseUp), name)

    def scroll(self, dx, dy):
        event = Quartz.CGEventCreateScrollWheelEvent(
            None,
            Quartz.kCGScrollEventUnitLine,
            2,
            int(dy),
            int(dx),
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)

    def key(self, name, down):
        code = KEYCODES.get(name)
        if code is None:
            print(f"unmapped key: {name}", flush=True)
            return
        event = Quartz.CGEventCreateKeyboardEvent(None, code, bool(down))
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def send_json(conn, payload):
    try:
        conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    except OSError:
        pass


def handle_client(conn, addr, return_edge):
    print(f"connected: {addr[0]}:{addr[1]}", flush=True)

    released_at = 0

    def release():
        nonlocal released_at
        now = time.monotonic()
        if now - released_at > 0.5:
            released_at = now
            send_json(conn, {"type": "release"})
            print("returned control to Windows", flush=True)

    inputter = MacInput(return_edge=return_edge, release_callback=release)

    with conn:
        file = conn.makefile("r", encoding="utf-8", newline="\n")
        try:
            for line in file:
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type")
                if msg_type == "move":
                    inputter.move(msg.get("dx", 0), msg.get("dy", 0))
                elif msg_type == "button":
                    inputter.button(msg.get("button", "left"), bool(msg.get("down")))
                elif msg_type == "scroll":
                    inputter.scroll(msg.get("dx", 0), msg.get("dy", 0))
                elif msg_type == "key":
                    inputter.key(msg.get("key", ""), bool(msg.get("down")))
                elif msg_type == "ping":
                    send_json(conn, {"type": "pong"})
        except OSError:
            pass

    print(f"disconnected: {addr[0]}:{addr[1]}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=45877)
    parser.add_argument("--return-edge", choices=["left", "right"], default="left")
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.listen, args.port))
    server.listen(1)

    print(f"Mac client listening on {args.listen}:{args.port}", flush=True)
    print("grant Accessibility permission to this terminal if input does not move", flush=True)

    while True:
        conn, addr = server.accept()
        handle_client(conn, addr, args.return_edge)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
