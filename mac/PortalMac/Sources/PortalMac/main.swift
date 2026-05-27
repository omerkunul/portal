import AppKit
import ApplicationServices
import Network
import Darwin
import SwiftUI

enum Edge: String, CaseIterable {
    case left
    case right
    case top
    case bottom

    var opposite: Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

func activeDisplayFrames() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        return []
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        return []
    }
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}

struct EdgeActivation {
    let edge: Edge
    let xRatio: Double
    let yRatio: Double
    let display: DisplayInfo
}

final class LocalInputForwarder {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var currentRunLoop: CFRunLoop?
    private var isControllingWindows = false
    private var lastPoint: CGPoint?
    private var activeSourceEdge: Edge = .right
    private var activeSourceDisplay: DisplayInfo?
    private var modifierStates: [String: Bool] = [:]
    private var suppressUntil = Date.distantPast
    private var cursorHidden = false
    private lazy var reverseKeyCodes: [CGKeyCode: String] = {
        Dictionary(uniqueKeysWithValues: InputInjector.sharedKeyCodes.map { ($0.value, $0.key) })
    }()

    var activationProvider: ((CGPoint) -> EdgeActivation?)?
    var onActivate: ((EdgeActivation) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onButton: ((String, Bool) -> Void)?
    var onScroll: ((Int, Int) -> Void)?
    var onKey: ((String, Bool) -> Void)?

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in
            self?.runTapLoop()
        }
        thread.name = "portal.mac.capture"
        thread.start()
        self.thread = thread
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let loop = currentRunLoop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        if let loop = currentRunLoop {
            CFRunLoopStop(loop)
        }
        currentRunLoop = nil
        thread = nil
    }

    func finishControlFromWindows(edge _: Edge, xRatio: Double, yRatio: Double) {
        isControllingWindows = false
        suppressUntil = Date().addingTimeInterval(0.35)
        setCursorHidden(false)
        guard let display = activeSourceDisplay else { return }
        let point = sourceReturnPoint(in: display.frame, edge: activeSourceEdge, xRatio: xRatio, yRatio: yRatio)
        CGWarpMouseCursorPosition(point)
        lastPoint = point
    }

    private func runTapLoop() {
        currentRunLoop = CFRunLoopGetCurrent()
        let mask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let forwarder = Unmanaged<LocalInputForwarder>.fromOpaque(refcon).takeUnretainedValue()
            return forwarder.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let point = event.location

        if !isControllingWindows {
            if Date() >= suppressUntil,
               isMoveEvent(type),
               let activation = activationProvider?(point)
            {
                isControllingWindows = true
                setCursorHidden(true)
                activeSourceEdge = activation.edge
                activeSourceDisplay = activation.display
                lastPoint = point
                onActivate?(activation)
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let previous = lastPoint ?? point
            lastPoint = point
            let dx = Int(round(point.x - previous.x))
            let dy = Int(round(point.y - previous.y))
            if dx != 0 || dy != 0 {
                onMove?(dx, dy)
            }
            return nil
        case .leftMouseDown:
            onButton?("left", true)
            return nil
        case .leftMouseUp:
            onButton?("left", false)
            return nil
        case .rightMouseDown:
            onButton?("right", true)
            return nil
        case .rightMouseUp:
            onButton?("right", false)
            return nil
        case .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? "middle" : "forward"
            onButton?(button, true)
            return nil
        case .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? "middle" : "forward"
            onButton?(button, false)
            return nil
        case .scrollWheel:
            let dx = Int(round(event.getDoubleValueField(.scrollWheelEventDeltaAxis2)))
            let dy = Int(round(event.getDoubleValueField(.scrollWheelEventDeltaAxis1)))
            if dx != 0 || dy != 0 {
                onScroll?(dx, dy)
            }
            return nil
        case .keyDown, .keyUp:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if let name = reverseKeyCodes[keyCode] {
                onKey?(name, type == .keyDown)
                return nil
            }
            return nil
        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard let name = reverseKeyCodes[keyCode] else { return nil }
            let flag = modifierFlag(for: name)
            let isDown = flag.map { event.flags.contains($0) } ?? false
            if modifierStates[name] != isDown {
                modifierStates[name] = isDown
                onKey?(name, isDown)
            }
            return nil
        default:
            return nil
        }
    }

    private func isMoveEvent(_ type: CGEventType) -> Bool {
        type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
    }

    private func sourceReturnPoint(in frame: CGRect, edge: Edge, xRatio: Double, yRatio: Double) -> CGPoint {
        let inset: CGFloat = 24
        switch edge {
        case .left:
            return CGPoint(x: frame.minX + inset, y: frame.minY + frame.height * CGFloat(max(0, min(1, yRatio))))
        case .right:
            return CGPoint(x: frame.maxX - inset, y: frame.minY + frame.height * CGFloat(max(0, min(1, yRatio))))
        case .top:
            return CGPoint(x: frame.minX + frame.width * CGFloat(max(0, min(1, xRatio))), y: frame.maxY - inset)
        case .bottom:
            return CGPoint(x: frame.minX + frame.width * CGFloat(max(0, min(1, xRatio))), y: frame.minY + inset)
        }
    }

    private func modifierFlag(for name: String) -> CGEventFlags? {
        switch name {
        case "shift", "right_shift": return .maskShift
        case "ctrl", "right_ctrl": return .maskControl
        case "alt", "right_alt": return .maskAlternate
        case "cmd": return .maskCommand
        case "caps_lock": return .maskAlphaShift
        default: return nil
        }
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard cursorHidden != hidden else { return }
        cursorHidden = hidden
        if hidden {
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }
}

final class InputInjector {
    enum MoveMode {
        case event
        case warp
    }

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    static let sharedKeyCodes: [String: CGKeyCode] = [
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
        "page_up": 116, "page_down": 121, "f1": 122, "f2": 120,
        "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
    private let keyCodes = InputInjector.sharedKeyCodes

    private var buttonsDown = Set<String>()
    private var activeFlags: CGEventFlags = []
    private var mouseEventNumber: Int64 = 1
    private var activeClickStates: [String: Int64] = [:]
    private var lastClickName: String?
    private var lastClickPoint: CGPoint?
    private var lastClickTime = Date.distantPast
    private var lastClickState: Int64 = 0
    private var windowsControlDown = false
    private var remotePosition: CGPoint?
    private var remoteBounds: CGRect?
    var onReturnToWindows: ((Edge, Double, Double) -> Void)?
    var returnAllowedProvider: ((Edge, CGPoint) -> Bool)?
    var returnEdge: Edge = .left
    var moveMode: MoveMode = .event
    private var lastReleaseAt = Date.distantPast

    func move(dx: Int, dy: Int) {
        let current = remotePosition ?? currentMousePosition()
        let proposed = CGPoint(
            x: current.x + CGFloat(dx),
            y: current.y + CGFloat(dy)
        )
        let next = clampToDisplaySpace(current: current, proposed: proposed)
        remotePosition = next
        let activeButton = buttonsDown.first ?? "left"
        let type = buttonsDown.isEmpty ? CGEventType.mouseMoved : dragType(for: activeButton)
        if moveMode == .warp && buttonsDown.isEmpty {
            CGWarpMouseCursorPosition(next)
        } else {
            postMouse(type: type, point: next, button: mouseButton(for: activeButton), dx: dx, dy: dy, buttonNumber: mouseButtonNumber(for: activeButton))
        }
        checkReturnEdge(next)
    }

    func activate(from edge: Edge, yRatio: Double, xRatio: Double, targetFrame: CGRect? = nil) {
        let point = targetFrame.map { entryPoint(from: edge, xRatio: xRatio, yRatio: yRatio, in: $0) }
            ?? entryPoint(from: edge, xRatio: xRatio, yRatio: yRatio)
        let bounds = displayFrame(containing: point) ?? desktopBounds()
        remoteBounds = bounds
        remotePosition = point
        CGWarpMouseCursorPosition(point)
        postMouse(type: .mouseMoved, point: point, button: .left)
    }

    func testMove() {
        move(dx: 180, dy: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.move(dx: -180, dy: 0)
        }
    }

    func button(name: String, down: Bool) {
        let pos = remotePosition ?? currentMousePosition()
        remotePosition = pos
        CGWarpMouseCursorPosition(pos)
        if down {
            buttonsDown.insert(name)
            let clickState = name == "left" ? nextClickState(for: name, at: pos) : 1
            activeClickStates[name] = clickState
            postClick(type: mouseDownType(for: name), point: pos, button: mouseButton(for: name), down: true, clickState: clickState, buttonNumber: mouseButtonNumber(for: name))
        } else {
            buttonsDown.remove(name)
            let clickState = activeClickStates[name] ?? 1
            activeClickStates[name] = nil
            postClick(type: mouseUpType(for: name), point: pos, button: mouseButton(for: name), down: false, clickState: clickState, buttonNumber: mouseButtonNumber(for: name))
        }
    }

    func testClick() {
        let pos = currentMousePosition()
        let clickState = nextClickState(for: "left", at: pos)
        activeClickStates["left"] = clickState
        postClick(type: .leftMouseDown, point: pos, button: .left, down: true, clickState: clickState)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let state = self?.activeClickStates["left"] ?? 1
            self?.activeClickStates["left"] = nil
            self?.postClick(type: .leftMouseUp, point: pos, button: .left, down: false, clickState: state)
        }
    }

    func scroll(dx: Int, dy: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else { return }
        postEvent(event)
    }

    func key(name: String, down: Bool, text: String? = nil, ctrl: Bool = false, alt: Bool = false) {
        if isWindowsControlKey(name) {
            windowsControlDown = down
            return
        }

        let useMacCommand = (ctrl || windowsControlDown) && !alt && isMacCommandShortcut(name)
        if let text, down, !text.isEmpty, !useMacCommand {
            postUnicodeText(text, flags: textInputFlags(ctrl: ctrl, alt: alt))
            return
        }

        guard let code = keyCodes[name],
              let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
        else { return }

        if let flag = modifierFlag(for: name) {
            if down {
                activeFlags.insert(flag)
                event.flags = activeFlags
            } else {
                activeFlags.remove(flag)
                event.flags = activeFlags
            }
        } else {
            var flags = activeFlags
            if useMacCommand {
                flags.remove(.maskControl)
                flags.insert(.maskCommand)
            }
            event.flags = flags
            if !useMacCommand {
                setUnicodeStringIfPrintable(name, on: event)
            }
        }
        event.post(tap: .cghidEventTap)
    }

    private func postUnicodeText(_ text: String, flags: CGEventFlags = []) {
        let units = Array(text.utf16)
        guard !units.isEmpty,
              let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
        else { return }

        var mutableUnits = units
        let length = mutableUnits.count
        mutableUnits.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
        }
        down.flags = flags
        down.post(tap: .cghidEventTap)
    }

    private func currentMousePosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton, dx: Int = 0, dy: Int = 0, buttonNumber: Int64? = nil) {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber ?? Int64(button.rawValue))
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.flags = activeFlags
        event.post(tap: .cghidEventTap)
    }

    private func postClick(type: CGEventType, point: CGPoint, button: CGMouseButton, down: Bool, clickState: Int64, buttonNumber: Int64? = nil) {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber ?? mouseButtonNumber(for: button))
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.mouseEventNumber, value: mouseEventNumber)
        event.setDoubleValueField(.mouseEventPressure, value: down ? 1.0 : 0.0)
        event.flags = activeFlags
        postEvent(event)
        if !down {
            mouseEventNumber += 1
        }
    }

    private func nextClickState(for name: String, at point: CGPoint) -> Int64 {
        let now = Date()
        let interval = now.timeIntervalSince(lastClickTime)
        let sameButton = lastClickName == name
        let closeEnough: Bool
        if let lastClickPoint {
            closeEnough = abs(lastClickPoint.x - point.x) <= 8 && abs(lastClickPoint.y - point.y) <= 8
        } else {
            closeEnough = false
        }

        let maxInterval = max(0.2, NSEvent.doubleClickInterval)
        let state: Int64 = sameButton && closeEnough && interval <= maxInterval ? lastClickState + 1 : 1
        lastClickName = name
        lastClickPoint = point
        lastClickTime = now
        lastClickState = state
        return state
    }

    private func postEvent(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    private func modifierFlag(for name: String) -> CGEventFlags? {
        switch name {
        case "shift", "right_shift": return .maskShift
        case "ctrl", "right_ctrl": return .maskControl
        case "alt", "right_alt": return .maskAlternate
        case "cmd": return .maskCommand
        case "caps_lock": return .maskAlphaShift
        default: return nil
        }
    }

    private func isWindowsControlKey(_ name: String) -> Bool {
        name == "ctrl" || name == "right_ctrl"
    }

    private func isMacCommandShortcut(_ name: String) -> Bool {
        if name.count == 1 { return true }
        switch name {
        case "tab", "space", "backspace", "delete", "left", "right", "up", "down", "home", "end":
            return true
        default:
            return false
        }
    }

    private func textInputFlags(ctrl: Bool, alt: Bool) -> CGEventFlags {
        if ctrl && alt {
            // Windows AltGr is reported as Ctrl+Alt. For text, emit the produced
            // character without carrying shortcut modifiers into macOS.
            return []
        }
        return activeFlags
    }

    private func setUnicodeStringIfPrintable(_ name: String, on event: CGEvent) {
        guard name.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII else { return }
        var chars = Array(String(scalar).utf16)
        let length = chars.count
        chars.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                event.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            }
        }
    }

    private func displayFrames() -> [CGRect] {
        activeDisplayFrames()
    }

    private func primaryDisplayFrame() -> CGRect? {
        let id = CGMainDisplayID()
        let frame = CGDisplayBounds(id)
        return frame.isEmpty ? nil : frame
    }

    private func desktopBounds() -> CGRect {
        let frames = displayFrames()
        guard var union = frames.first else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        for frame in frames.dropFirst() {
            union = union.union(frame)
        }
        return union
    }

    private func displayFrame(containing point: CGPoint) -> CGRect? {
        displayFrames().first { $0.contains(point) }
    }

    private func nearestDisplayFrame(to point: CGPoint) -> CGRect? {
        displayFrames().min { lhs, rhs in
            distanceSquared(from: point, to: lhs) < distanceSquared(from: point, to: rhs)
        }
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = max(rect.minX, min(rect.maxX, point.x))
        let y = max(rect.minY, min(rect.maxY, point.y))
        let dx = point.x - x
        let dy = point.y - y
        return dx * dx + dy * dy
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: max(rect.minX, min(rect.maxX - 1, point.x)),
            y: max(rect.minY, min(rect.maxY - 1, point.y))
        )
    }

    private func clampToDisplaySpace(current: CGPoint, proposed: CGPoint) -> CGPoint {
        if displayFrame(containing: proposed) != nil {
            return proposed
        }
        if let currentFrame = displayFrame(containing: current) {
            return clamp(proposed, to: currentFrame)
        }
        if let nearest = nearestDisplayFrame(to: proposed) {
            return clamp(proposed, to: nearest)
        }
        return proposed
    }

    private func entryPoint(from edge: Edge, xRatio: Double, yRatio: Double) -> CGPoint {
        let frames = displayFrames()
        guard !frames.isEmpty else {
            return CGPoint(x: 24, y: 24)
        }

        let inset: CGFloat = 24
        let frame = primaryDisplayFrame() ?? frames[0]

        switch edge {
        case .left, .right:
            let desiredY = frame.minY + frame.height * CGFloat(max(0, min(1, yRatio)))
            let x = edge == .left ? frame.maxX - inset : frame.minX + inset
            let y = max(frame.minY, min(frame.maxY - 1, desiredY))
            return CGPoint(x: x, y: y)
        case .top, .bottom:
            let desiredX = frame.minX + frame.width * CGFloat(max(0, min(1, xRatio)))
            let x = max(frame.minX, min(frame.maxX - 1, desiredX))
            let y = edge == .top ? frame.maxY - inset : frame.minY + inset
            return CGPoint(x: x, y: y)
        }
    }

    private func entryPoint(from edge: Edge, xRatio: Double, yRatio: Double, in frame: CGRect) -> CGPoint {
        let inset: CGFloat = 24
        switch edge {
        case .left:
            return CGPoint(
                x: frame.maxX - inset,
                y: frame.minY + frame.height * CGFloat(max(0, min(1, yRatio)))
            )
        case .right:
            return CGPoint(
                x: frame.minX + inset,
                y: frame.minY + frame.height * CGFloat(max(0, min(1, yRatio)))
            )
        case .top:
            return CGPoint(
                x: frame.minX + frame.width * CGFloat(max(0, min(1, xRatio))),
                y: frame.maxY - inset
            )
        case .bottom:
            return CGPoint(
                x: frame.minX + frame.width * CGFloat(max(0, min(1, xRatio))),
                y: frame.minY + inset
            )
        }
    }

    private func checkReturnEdge(_ point: CGPoint) {
        guard let frame = remoteBounds ?? displayFrame(containing: point) ?? nearestDisplayFrame(to: point) else { return }
        let threshold: CGFloat = 1.5
        let shouldRelease = switch returnEdge {
        case .left:
            point.x <= frame.minX + threshold
        case .right:
            point.x >= frame.maxX - 1 - threshold
        case .top:
            point.y <= frame.minY + threshold
        case .bottom:
            point.y >= frame.maxY - 1 - threshold
        }
        if shouldRelease, returnAllowedProvider?(returnEdge, point) == false {
            return
        }
        if shouldRelease && Date().timeIntervalSince(lastReleaseAt) > 0.5 {
            lastReleaseAt = Date()
            let xRatio = frame.width <= 1 ? 0.5 : Double((point.x - frame.minX) / frame.width)
            let yRatio = frame.height <= 1 ? 0.5 : Double((point.y - frame.minY) / frame.height)
            onReturnToWindows?(returnEdge, max(0, min(1, xRatio)), max(0, min(1, yRatio)))
        }
    }

    private func mouseButton(for name: String) -> CGMouseButton {
        switch name {
        case "right": return .right
        case "middle", "back", "forward": return .center
        default: return .left
        }
    }

    private func mouseButtonNumber(for button: CGMouseButton) -> Int64 {
        Int64(button.rawValue)
    }

    private func mouseButtonNumber(for name: String) -> Int64 {
        switch name {
        case "back": return 3
        case "forward": return 4
        default: return Int64(mouseButton(for: name).rawValue)
        }
    }

    private func mouseDownType(for name: String) -> CGEventType {
        switch name {
        case "right": return .rightMouseDown
        case "middle", "back", "forward": return .otherMouseDown
        default: return .leftMouseDown
        }
    }

    private func mouseUpType(for name: String) -> CGEventType {
        switch name {
        case "right": return .rightMouseUp
        case "middle", "back", "forward": return .otherMouseUp
        default: return .leftMouseUp
        }
    }

    private func dragType(for name: String) -> CGEventType {
        switch name {
        case "right": return .rightMouseDragged
        case "middle", "back", "forward": return .otherMouseDragged
        default: return .leftMouseDragged
        }
    }
}

struct MotionSample {
    var packets = 0
    var raw = 0
    var distance = 0
    var maxReceiveGapMs = 0.0
    var maxSenderGapMs = 0.0
    var lostPackets = 0
}

struct MotionSummary {
    var packets = 0
    var raw = 0
    var maxReceiveGapMs = 0.0
    var maxSenderGapMs = 0.0
    var lostPackets = 0
}

final class MotionProbe {
    private let lock = NSLock()
    private let bucketNs: UInt64 = 33_333_333
    private var samples = Array(repeating: MotionSample(), count: 180)
    private var index = 0
    private var bucketStartNs = DispatchTime.now().uptimeNanoseconds
    private var lastPacketNs: UInt64?
    private var lastSequence: Int?

    func record(dx: Int, dy: Int, raw: Int, senderGapMs: Double = 0, sequence: Int? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        advance(to: now)
        let gap = lastPacketNs.map { Double(now - $0) / 1_000_000.0 } ?? 0
        if let sequence {
            if let lastSequence, sequence > lastSequence + 1 {
                samples[index].lostPackets += sequence - lastSequence - 1
            }
            lastSequence = sequence
        }
        samples[index].packets += 1
        samples[index].raw += max(raw, 1)
        samples[index].distance += abs(dx) + abs(dy)
        samples[index].maxReceiveGapMs = max(samples[index].maxReceiveGapMs, gap)
        samples[index].maxSenderGapMs = max(samples[index].maxSenderGapMs, senderGapMs)
        lastPacketNs = now
        lock.unlock()
    }

    func snapshot() -> [MotionSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        advance(to: now)
        let next = (index + 1) % samples.count
        let ordered = Array(samples[next...]) + Array(samples[..<next])
        lock.unlock()
        return ordered
    }

    func summary(sampleCount: Int = 30) -> MotionSummary {
        let recent = snapshot().suffix(sampleCount)
        return MotionSummary(
            packets: recent.reduce(0) { $0 + $1.packets },
            raw: recent.reduce(0) { $0 + $1.raw },
            maxReceiveGapMs: recent.map(\.maxReceiveGapMs).max() ?? 0,
            maxSenderGapMs: recent.map(\.maxSenderGapMs).max() ?? 0,
            lostPackets: recent.reduce(0) { $0 + $1.lostPackets }
        )
    }

    private func advance(to now: UInt64) {
        guard now > bucketStartNs else { return }
        var steps = Int((now - bucketStartNs) / bucketNs)
        guard steps > 0 else { return }
        if steps > samples.count {
            steps = samples.count
        }
        for _ in 0..<steps {
            index = (index + 1) % samples.count
            samples[index] = MotionSample()
            bucketStartNs += bucketNs
        }
        if now - bucketStartNs > bucketNs * UInt64(samples.count) {
            bucketStartNs = now
        }
    }
}

final class MotionLogWriter {
    private let probe: MotionProbe
    private let url = URL(fileURLWithPath: "/tmp/portal-motion.log")
    private var timer: Timer?

    init(probe: MotionProbe) {
        self.probe = probe
        try? "time,pkt_per_s,raw_per_s,win_gap_ms,mac_gap_ms,lost\n".write(to: url, atomically: true, encoding: .utf8)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.writeSample()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func writeSample() {
        let summary = probe.summary()
        let line = String(
            format: "%@,%d,%d,%.1f,%.1f,%d\n",
            isoTimestamp(),
            summary.packets,
            summary.raw,
            summary.maxSenderGapMs,
            summary.maxReceiveGapMs,
            summary.lostPackets
        )
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch { }
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

final class MotionGraphView: NSView {
    var probe: MotionProbe?
    private var timer: Timer?
    private var cachedSamples: [MotionSample] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cachedSamples = self.probe?.snapshot() ?? []
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 460, height: 150)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x121317).setFill()
        bounds.fill()

        let plot = bounds.insetBy(dx: 10, dy: 24)
        NSColor(hex: 0x414755, alpha: 0.5).setStroke()
        for step in 0...3 {
            let y = plot.minY + plot.height * CGFloat(step) / 3.0
            let path = NSBezierPath()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.line(to: CGPoint(x: plot.maxX, y: y))
            path.stroke()
        }

        guard !cachedSamples.isEmpty else {
            return
        }

        let maxDistance = max(8, cachedSamples.map(\.distance).max() ?? 8)
        let barWidth = max(1, plot.width / CGFloat(cachedSamples.count))

        for (i, sample) in cachedSamples.enumerated() {
            let x = plot.minX + CGFloat(i) * barWidth
            let ratio = min(1.0, CGFloat(sample.distance) / CGFloat(maxDistance))
            let height = max(sample.packets > 0 ? 2 : 0, plot.height * ratio)
            let rect = NSRect(x: x, y: plot.minY, width: max(1, barWidth - 1), height: height)
            if sample.maxSenderGapMs > 80 {
                NSColor.systemRed.withAlphaComponent(0.9).setFill()
            } else if sample.maxReceiveGapMs > 80 || sample.lostPackets > 0 {
                NSColor.systemOrange.withAlphaComponent(0.9).setFill()
            } else if sample.maxSenderGapMs > 35 || sample.maxReceiveGapMs > 35 {
                NSColor.systemYellow.withAlphaComponent(0.9).setFill()
            } else {
                NSColor(hex: 0x32d74b, alpha: 0.82).setFill()
            }
            rect.fill()
        }
    }
}

struct DisplayInfo {
    let name: String
    let frame: CGRect
    let isPrimary: Bool
}

struct ArrangementItem {
    let id: String
    let machine: String
    let index: Int
    let name: String
    let nativeFrame: CGRect
    let virtualFrame: CGRect
    let isPrimary: Bool
}

final class PortalUIModel: ObservableObject {
    @Published var port = "45877"
    @Published var edge = Edge.right
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var status = "Stopped"
    @Published var ip = "checking..."
    @Published var accessibility = "checking..."
    @Published var accessibilityOK = false
    @Published var awdlEnabled = true
    @Published var awdlText = "checking..."
    @Published var awdlColor: Color = .secondary
    @Published var stats = "Stats: idle"
    @Published var arrangement = "checking..."
    @Published var windowsSetupStatus = "Ready to prepare a Windows host"
    @Published var windowsInstallerURL = ""
    @Published var windowsInstallCommand = ""
    @Published var windowsHosts: [WindowsHostCandidate] = []
    @Published var isScanningWindows = false
    @Published var isServingInstaller = false
}

struct WindowsHostCandidate: Identifiable, Hashable {
    let id = UUID()
    let ip: String
    let ports: [String]
    let name: String

    var summary: String {
        let portText = ports.isEmpty ? "no install ports" : ports.joined(separator: ", ")
        return name.isEmpty ? portText : "\(portText) · \(name)"
    }
}

extension Color {
    static var portalOrange: Color { Color(nsColor: .systemOrange) }
    static var portalGreen: Color { Color(nsColor: .systemGreen) }
    static var portalBackground: Color { Color(nsColor: NSColor(hex: 0x121317)) }
    static var portalSurfaceLow: Color { Color(nsColor: NSColor(hex: 0x1a1b1f)) }
    static var portalSurface: Color { Color(nsColor: NSColor(hex: 0x1e1f23)) }
    static var portalSurfaceHigh: Color { Color(nsColor: NSColor(hex: 0x292a2e)) }
    static var portalBorder: Color { Color(nsColor: NSColor(hex: 0x414755)) }
    static var portalText: Color { Color(nsColor: NSColor(hex: 0xe3e2e7)) }
    static var portalMuted: Color { Color(nsColor: NSColor(hex: 0xc1c6d7)).opacity(0.72) }
    static var portalPrimary: Color { Color(nsColor: NSColor(hex: 0x007aff)) }
    static var portalSuccess: Color { Color(nsColor: NSColor(hex: 0x32d74b)) }
    static var portalDanger: Color { Color(nsColor: NSColor(hex: 0xff453a)) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private enum PortalTab: String, CaseIterable {
    case control = "Control"
    case setup = "Windows Setup"
    case arrange = "Arrange"
    case settings = "Settings"
}

struct MotionGraphRepresentable: NSViewRepresentable {
    let view: MotionGraphView

    func makeNSView(context: Context) -> MotionGraphView {
        view
    }

    func updateNSView(_ nsView: MotionGraphView, context: Context) {}
}

struct DisplayArrangementRepresentable: NSViewRepresentable {
    let view: DisplayArrangementView

    func makeNSView(context: Context) -> DisplayArrangementView {
        view
    }

    func updateNSView(_ nsView: DisplayArrangementView, context: Context) {
        nsView.needsDisplay = true
    }
}

struct PortalRootView: View {
    @ObservedObject var model: PortalUIModel
    @State private var selectedTab: PortalTab = .control
    @AppStorage("portal.clipboardSync.enabled") private var clipboardSyncEnabled = true
    @AppStorage("portal.autoStart.enabled") private var autoStartEnabled = true
    @AppStorage("portal.autoUpdate.enabled") private var autoUpdateEnabled = false
    @AppStorage("portal.autoScan.enabled") private var autoScanEnabled = true
    @AppStorage("portal.reconnect.enabled") private var reconnectEnabled = true
    @AppStorage("portal.notifications.enabled") private var notificationsEnabled = true
    @AppStorage("portal.launchAtLogin.enabled") private var launchAtLoginEnabled = false
    @AppStorage("portal.debugLogs.enabled") private var debugLogsEnabled = false
    let motionGraph: MotionGraphView
    let arrangementView: DisplayArrangementView
    let toggleServer: () -> Void
    let toggleAwdl: (Bool) -> Void
    let openAccessibility: () -> Void
    let resetArrangement: () -> Void
    let scanWindowsHosts: () -> Void
    let toggleInstallerServer: () -> Void
    let copyWindowsInstallCommand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            VStack(spacing: 0) {
                header

                pageContainer {
                    switch selectedTab {
                    case .control:
                        controlView
                    case .setup:
                        windowsSetupTab
                    case .arrange:
                        arrangementTab
                    case .settings:
                        settingsTab
                    }
                }

                statsPanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.portalBackground)
        .frame(width: 1180, height: 780)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func pageContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.portalBackground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Portal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.portalText)
                Spacer()
            }
            .padding(.leading, 86)
            .padding(.trailing, 16)
            .frame(height: 56)

            VStack(spacing: 8) {
                ForEach(PortalTab.allCases, id: \.self) { tab in
                    sidebarButton(tab)
                }
            }
            .padding(.top, 64)
            .padding(.horizontal, 14)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                sidebarFooter("Support", systemImage: "questionmark.circle")
                sidebarFooter("Logs", systemImage: "terminal")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .frame(maxHeight: .infinity)
        .background(Color.portalSurfaceLow.opacity(0.92))
    }

    private func sidebarButton(_ tab: PortalTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sidebarIcon(for: tab))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(selectedTab == tab ? Color.portalText : Color.portalMuted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .background(selectedTab == tab ? Color.portalSurfaceHigh : Color.clear)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func sidebarIcon(for tab: PortalTab) -> String {
        switch tab {
        case .control: return "computermouse"
        case .setup: return "desktopcomputer.and.arrow.down"
        case .arrange: return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }

    private func sidebarFooter(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.portalMuted)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(selectedTab.rawValue)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.portalText)

            statusBadge

            Spacer()

            Button(action: toggleServer) {
                HStack(spacing: 7) {
                    Image(systemName: model.isRunning ? "stop.circle" : "play.circle")
                    Text(model.isRunning ? "Stop" : (model.isStarting ? "Starting..." : "Start"))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(height: 28)
                .padding(.horizontal, 13)
                .background(model.isRunning ? Color.portalDanger.opacity(0.38) : Color.portalPrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(model.isRunning ? Color.portalDanger.opacity(0.55) : Color.portalPrimary.opacity(0.5), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(model.isStarting)
        }
        .frame(height: 56)
        .padding(.horizontal, 24)
        .background(Color.portalBackground)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? Color.portalSuccess : Color.portalMuted)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(model.isRunning ? Color.portalSuccess : Color.portalMuted)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background((model.isRunning ? Color.portalSuccess : Color.portalMuted).opacity(0.12))
        .overlay {
            Capsule()
                .stroke((model.isRunning ? Color.portalSuccess : Color.portalMuted).opacity(0.28), lineWidth: 1)
        }
        .clipShape(Capsule())
    }

    private var controlView: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                PortalCard(title: "Network Configuration", systemImage: "network") {
                    DataRow("Primary Port") {
                        TextField("", text: $model.port)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(nsColor: NSColor(hex: 0xadc6ff)))
                    }
                    DataRow("Local IP") {
                        Text(model.ip)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.portalText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    DataRow("Connection Status") {
                        HStack(spacing: 5) {
                            Image(systemName: model.isRunning ? "checkmark.circle" : "circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(model.isRunning ? "Active" : "Idle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(model.isRunning ? Color.portalSuccess : Color.portalMuted)
                    }
                }

                PortalCard(title: "System Permissions", systemImage: "lock.shield") {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill((model.accessibilityOK ? Color.portalSuccess : Color.portalOrange).opacity(0.18))
                                .frame(width: 34, height: 34)
                            Image(systemName: model.accessibilityOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(model.accessibilityOK ? Color.portalSuccess : Color.portalOrange)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility Access")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.portalText)
                            Text(model.accessibilityOK ? "Granted & Active" : model.accessibility)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.accessibilityOK ? Color.portalSuccess : Color.portalOrange)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.portalSurfaceHigh.opacity(0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    DataRow("AWDL (Low Latency)") {
                        Toggle("", isOn: Binding(
                            get: { model.awdlEnabled },
                            set: { toggleAwdl($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Button(action: openAccessibility) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.square")
                            Text("Open Accessibility Settings")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.portalText)
                    .background(Color.portalSurfaceLow)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.portalBorder.opacity(0.48), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            liveActivityCard
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var arrangementTab: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $model.edge) {
                    ForEach(Edge.allCases, id: \.self) { edge in
                        Text(edge.rawValue.capitalized).tag(edge)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Button("Reset", action: resetArrangement)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Spacer()

                Text(model.arrangement.replacingOccurrences(of: "\n", with: " · "))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.portalMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.portalSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            DisplayArrangementRepresentable(view: arrangementView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.portalBorder.opacity(0.42), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var windowsSetupTab: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                PortalCard(title: "Windows Installer", systemImage: "shippingbox") {
                    DataRow("Status") {
                        Text(model.windowsSetupStatus)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.portalText)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }

                    DataRow("Installer URL") {
                        Text(model.windowsInstallerURL.isEmpty ? "not serving" : model.windowsInstallerURL)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(model.windowsInstallerURL.isEmpty ? Color.portalMuted : Color(nsColor: NSColor(hex: 0xadc6ff)))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 10) {
                        Button(action: toggleInstallerServer) {
                            Label(model.isServingInstaller ? "Stop Installer" : "Serve Installer", systemImage: model.isServingInstaller ? "stop.circle" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(model.isServingInstaller ? Color.portalDanger.opacity(0.42) : Color.portalPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                        Button(action: copyWindowsInstallCommand) {
                            Label("Copy Command", systemImage: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.portalText)
                        .background(Color.portalSurfaceLow)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.portalBorder.opacity(0.48), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .disabled(model.windowsInstallCommand.isEmpty)
                    }

                    Text(model.windowsInstallCommand.isEmpty ? "Start installer sharing, then paste the copied command into PowerShell on the Windows machine." : model.windowsInstallCommand)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.portalMuted)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.portalSurfaceHigh.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(height: 258)

                PortalCard(title: "Network Scan", systemImage: "network.badge.shield.half.filled") {
                    networkScanPanel
                }
                .frame(height: 258)
            }

            PortalCard(title: "Setup Path", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                HStack(spacing: 12) {
                    setupStep("1", "Find", "Scan LAN for the Windows host.")
                    setupStep("2", "Install", "Serve the installer from this Mac.")
                    setupStep("3", "Automate", "Enable SSH once for remote updates.")
                }
            }
            .frame(height: 112)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var settingsTab: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                PortalCard(title: "Sync", systemImage: "arrow.triangle.2.circlepath") {
                    settingsToggle("Copy & Paste", "Sync text and images between Mac and Windows.", isOn: $clipboardSyncEnabled)
                    settingsToggle("Auto Reconnect", "Keep the Windows host attached after sleep or network changes.", isOn: $reconnectEnabled)
                    settingsToggle("Notifications", "Show setup and connection alerts.", isOn: $notificationsEnabled)
                }
                .frame(height: 184)

                PortalCard(title: "Startup", systemImage: "power") {
                    settingsToggle("Open at Login", "Start Portal when this Mac signs in.", isOn: $launchAtLoginEnabled)
                    settingsToggle("Start Server", "Begin listening automatically when Portal opens.", isOn: $autoStartEnabled)
                    settingsToggle("Auto Scan", "Refresh Windows host discovery when setup opens.", isOn: $autoScanEnabled)
                }
                .frame(height: 184)
            }

            HStack(alignment: .top, spacing: 18) {
                PortalCard(title: "Maintenance", systemImage: "wrench.and.screwdriver") {
                    settingsToggle("Auto Update", "Check for Windows host updates during setup.", isOn: $autoUpdateEnabled)
                    settingsToggle("Debug Logs", "Write extra input and connection diagnostics.", isOn: $debugLogsEnabled)
                    DataRow("Windows Package") {
                        Text("Portal-Windows-installer.zip")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.portalMuted)
                            .lineLimit(1)
                    }
                }
                .frame(height: 184)

                PortalCard(title: "Low Latency", systemImage: "speedometer") {
                    DataRow("AWDL") {
                        Toggle("", isOn: Binding(
                            get: { model.awdlEnabled },
                            set: { toggleAwdl($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    DataRow("Accessibility") {
                        Text(model.accessibilityOK ? "Granted" : "Required")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.accessibilityOK ? Color.portalSuccess : Color.portalOrange)
                    }
                    Button(action: openAccessibility) {
                        Label("Open Accessibility", systemImage: "arrow.up.forward.square")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.portalText)
                    .background(Color.portalSurfaceLow)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.portalBorder.opacity(0.48), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .frame(height: 184)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func settingsToggle(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.portalText)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.portalMuted)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(8)
        .background(Color.portalSurfaceHigh.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var networkScanPanel: some View {
        VStack(spacing: 12) {
            Button(action: scanWindowsHosts) {
                Label(model.isScanningWindows ? "Scanning..." : "Scan Network", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(model.isScanningWindows ? Color.portalMuted.opacity(0.35) : Color.portalPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .disabled(model.isScanningWindows)

            Group {
                if model.windowsHosts.isEmpty {
                    Text("No Windows candidates yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.portalMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.windowsHosts.prefix(3))) { host in
                            windowsHostRow(host)
                        }

                        if model.windowsHosts.count > 3 {
                            Text("+ \(model.windowsHosts.count - 3) more hosts")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.portalMuted)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(height: 128)
        }
    }

    private func windowsHostRow(_ host: WindowsHostCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: host.ports.contains("22") ? "checkmark.circle.fill" : "desktopcomputer")
                .foregroundStyle(host.ports.contains("22") ? Color.portalSuccess : Color.portalOrange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.ip)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.portalText)
                Text(host.summary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.portalMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(9)
        .background(Color.portalSurfaceHigh.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func setupStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.portalPrimary)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.portalText)
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.portalMuted)
                    .lineLimit(2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live Activity", systemImage: "chart.bar.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.portalText)
                Spacer()
                Text(model.stats)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.portalMuted)
                    .lineLimit(1)
            }

            MotionGraphRepresentable(view: motionGraph)
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(Color.portalSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.portalBorder.opacity(0.34), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var statsPanel: some View {
        EmptyView()
    }
}

struct PortalCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.portalText)

            Divider()
                .overlay(Color.portalBorder.opacity(0.35))

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.portalSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.portalBorder.opacity(0.34), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct DataRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.portalMuted)
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.portalBorder.opacity(0.24))
                .frame(height: 1)
        }
    }
}

final class DisplayArrangementView: NSView {
    private struct ViewTransform {
        let union: CGRect
        let origin: CGPoint
        let scale: CGFloat

        var visibleRect: NSRect {
            NSRect(
                x: origin.x,
                y: origin.y,
                width: union.width * scale,
                height: union.height * scale
            )
        }
    }

    private struct DragState {
        let machine: String
        let startPoint: CGPoint
        let originalOffset: CGPoint
        let transform: ViewTransform
    }

    private struct SnapMatch {
        let sourceFrame: CGRect
        let targetFrame: CGRect
    }

    private struct SnapResult {
        let offset: CGPoint
        let match: SnapMatch?
    }

    private let snapDistance: CGFloat = 48
    private let adjacencyTolerance: CGFloat = 24
    var macDisplays: [DisplayInfo] = [] {
        didSet { needsDisplay = true }
    }

    var windowsDisplays: [DisplayInfo] = [] {
        didSet { needsDisplay = true }
    }

    var machineOffsets: [String: CGPoint] = [:] {
        didSet { needsDisplay = true }
    }

    var onOffsetsChanged: (([String: CGPoint]) -> Void)?

    private var renderedRects: [(id: String, machine: String, rect: NSRect)] = []
    private var dragState: DragState?
    private var lastTransform: ViewTransform?
    private var pinnedTransform: ViewTransform?
    private var snapMatch: SnapMatch?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 900, height: 620)
    }

    func resetViewport() {
        pinnedTransform = nil
        snapMatch = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x121317).setFill()
        bounds.fill()

        let items = arrangementItems()
        guard !items.isEmpty else {
            drawText("No displays found", at: CGPoint(x: 16, y: bounds.midY), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            return
        }

        let transform = dragState?.transform ?? pinnedTransform ?? makeTransform(for: items)
        lastTransform = transform
        pinnedTransform = transform

        drawGrid(in: transform.visibleRect)
        NSColor(hex: 0x414755, alpha: 0.45).setStroke()
        NSBezierPath(rect: transform.visibleRect).stroke()
        renderedRects = []

        for item in items {
            let rect = map(item.virtualFrame, transform: transform)
            renderedRects.append((item.id, item.machine, rect))
            let color = item.machine == "mac"
                ? (item.isPrimary ? NSColor(hex: 0x007aff) : NSColor(hex: 0x32d74b))
                : (item.isPrimary ? NSColor(hex: 0xff9f0a) : NSColor(hex: 0x5e5ce6))
            color.withAlphaComponent(0.18).setFill()
            rect.fill()
            color.withAlphaComponent(0.95).setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.lineWidth = item.isPrimary ? 2.5 : 1.5
            path.stroke()

            let machineLabel = item.machine == "mac" ? "M" : "W"
            let number = "\(machineLabel)\(item.index + 1)\(item.isPrimary ? "*" : "")"
            drawCentered(number, in: rect, font: .boldSystemFont(ofSize: 22), color: .labelColor)

            let label = "\(item.name)\n\(Int(item.nativeFrame.width))x\(Int(item.nativeFrame.height))"
            let labelRect = NSRect(x: rect.minX + 5, y: rect.minY + 5, width: max(1, rect.width - 10), height: min(42, max(22, rect.height * 0.34)))
            drawCentered(label, in: labelRect, font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: NSColor(hex: 0xc1c6d7, alpha: 0.72))
        }

        if let snapMatch {
            drawSnapMatch(snapMatch, transform: transform)
        }
    }

    private func makeTransform(for items: [ArrangementItem]) -> ViewTransform {
        let union = items.dropFirst().reduce(items[0].virtualFrame) { $0.union($1.virtualFrame) }
        let drawing = bounds.insetBy(dx: 18, dy: 18)
        let scale = max(0.0001, min(drawing.width / max(1, union.width), drawing.height / max(1, union.height)))
        let drawnWidth = union.width * scale
        let drawnHeight = union.height * scale
        let origin = CGPoint(
            x: drawing.midX - drawnWidth / 2,
            y: drawing.midY - drawnHeight / 2
        )
        return ViewTransform(union: union, origin: origin, scale: scale)
    }

    func arrangementItems() -> [ArrangementItem] {
        arrangementItems(offsets: machineOffsets)
    }

    private func arrangementItems(offsets: [String: CGPoint]) -> [ArrangementItem] {
        let macDefaults = defaultFrames(for: macDisplays, machine: "mac", xOffset: 0)
        let windowsDefaults = defaultFrames(for: windowsDisplays, machine: "windows", xOffset: -(windowsGroupWidth() + 220))
        let defaults = macDefaults + windowsDefaults
        return defaults.map { item in
            let offset = offsets[item.machine] ?? .zero
            guard offset != .zero else { return item }
            return ArrangementItem(
                id: item.id,
                machine: item.machine,
                index: item.index,
                name: item.name,
                nativeFrame: item.nativeFrame,
                virtualFrame: item.virtualFrame.offsetBy(dx: offset.x, dy: offset.y),
                isPrimary: item.isPrimary
            )
        }
    }

    private func defaultFrames(for displays: [DisplayInfo], machine: String, xOffset: CGFloat) -> [ArrangementItem] {
        guard !displays.isEmpty else { return [] }
        let union = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        return displays.enumerated().map { index, display in
            let origin: CGPoint
            origin = CGPoint(
                x: display.frame.minX - union.minX + xOffset,
                y: union.maxY - display.frame.maxY
            )
            return ArrangementItem(
                id: displayId(machine: machine, display: display),
                machine: machine,
                index: index,
                name: display.name,
                nativeFrame: display.frame,
                virtualFrame: CGRect(origin: origin, size: display.frame.size),
                isPrimary: display.isPrimary
            )
        }
    }

    private func windowsGroupWidth() -> CGFloat {
        guard !windowsDisplays.isEmpty else { return 1920 }
        let union = windowsDisplays.dropFirst().reduce(windowsDisplays[0].frame) { $0.union($1.frame) }
        return union.width
    }

    private func displayId(machine: String, display: DisplayInfo) -> String {
        "\(machine)|\(display.name)|\(Int(display.frame.minX))|\(Int(display.frame.minY))|\(Int(display.frame.width))|\(Int(display.frame.height))"
    }

    private func map(_ frame: CGRect, transform: ViewTransform) -> NSRect {
        NSRect(
            x: transform.origin.x + (frame.minX - transform.union.minX) * transform.scale,
            y: transform.origin.y + (frame.minY - transform.union.minY) * transform.scale,
            width: max(8, frame.width * transform.scale),
            height: max(8, frame.height * transform.scale)
        )
    }

    private func drawSnapMatch(_ match: SnapMatch, transform: ViewTransform) {
        let source = map(match.sourceFrame, transform: transform)
        let target = map(match.targetFrame, transform: transform)
        NSColor(hex: 0x64d2ff, alpha: 0.95).setStroke()
        let sourcePath = NSBezierPath(roundedRect: source, xRadius: 7, yRadius: 7)
        sourcePath.lineWidth = 3
        sourcePath.stroke()
        let targetPath = NSBezierPath(roundedRect: target, xRadius: 7, yRadius: 7)
        targetPath.lineWidth = 3
        targetPath.stroke()

        let line = NSBezierPath()
        line.move(to: CGPoint(x: source.midX, y: source.midY))
        line.line(to: CGPoint(x: target.midX, y: target.midY))
        line.lineWidth = 2
        line.stroke()
    }

    private func drawGrid(in rect: NSRect) {
        NSColor(hex: 0x414755, alpha: 0.24).setStroke()
        let path = NSBezierPath()
        let step: CGFloat = 48
        var x = rect.minX
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.line(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = rect.minY
        while y <= rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.line(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = renderedRects.reversed().first(where: { $0.rect.contains(point) }) else {
            dragState = nil
            return
        }
        let transform = lastTransform ?? makeTransform(for: arrangementItems())
        pinnedTransform = transform
        dragState = DragState(
            machine: hit.machine,
            startPoint: point,
            originalOffset: machineOffsets[hit.machine] ?? .zero,
            transform: transform
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragState else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(
            x: (point.x - dragState.startPoint.x) / dragState.transform.scale,
            y: (point.y - dragState.startPoint.y) / dragState.transform.scale
        )
        let proposed = CGPoint(
            x: dragState.originalOffset.x + delta.x,
            y: dragState.originalOffset.y + delta.y
        )
        let snapped = snappedOffset(for: dragState.machine, proposed: proposed)
        machineOffsets[dragState.machine] = snapped.offset
        snapMatch = snapped.match
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragState != nil else { return }
        dragState = nil
        snapMatch = nil
        onOffsetsChanged?(machineOffsets)
    }

    private func snappedOffset(for machine: String, proposed: CGPoint) -> SnapResult {
        var offsets = machineOffsets
        offsets[machine] = proposed
        let items = arrangementItems(offsets: offsets)
        let moving = items.filter { $0.machine == machine }
        let anchors = items.filter { $0.machine != machine }
        guard !moving.isEmpty, !anchors.isEmpty else {
            return SnapResult(offset: proposed, match: nil)
        }

        var bestOffset = proposed
        var bestMatch: SnapMatch?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for source in moving {
            for target in anchors {
                evaluateSnap(
                    source: source.virtualFrame,
                    target: target.virtualFrame,
                    proposed: proposed,
                    edgeDelta: CGPoint(x: target.virtualFrame.minX - source.virtualFrame.maxX, y: 0),
                    axisDelta: verticalSnapDelta(source.virtualFrame, target.virtualFrame),
                    bestOffset: &bestOffset,
                    bestMatch: &bestMatch,
                    bestScore: &bestScore
                )
                evaluateSnap(
                    source: source.virtualFrame,
                    target: target.virtualFrame,
                    proposed: proposed,
                    edgeDelta: CGPoint(x: target.virtualFrame.maxX - source.virtualFrame.minX, y: 0),
                    axisDelta: verticalSnapDelta(source.virtualFrame, target.virtualFrame),
                    bestOffset: &bestOffset,
                    bestMatch: &bestMatch,
                    bestScore: &bestScore
                )
                evaluateSnap(
                    source: source.virtualFrame,
                    target: target.virtualFrame,
                    proposed: proposed,
                    edgeDelta: CGPoint(x: 0, y: target.virtualFrame.minY - source.virtualFrame.maxY),
                    axisDelta: horizontalSnapDelta(source.virtualFrame, target.virtualFrame),
                    bestOffset: &bestOffset,
                    bestMatch: &bestMatch,
                    bestScore: &bestScore
                )
                evaluateSnap(
                    source: source.virtualFrame,
                    target: target.virtualFrame,
                    proposed: proposed,
                    edgeDelta: CGPoint(x: 0, y: target.virtualFrame.maxY - source.virtualFrame.minY),
                    axisDelta: horizontalSnapDelta(source.virtualFrame, target.virtualFrame),
                    bestOffset: &bestOffset,
                    bestMatch: &bestMatch,
                    bestScore: &bestScore
                )
            }
        }

        return SnapResult(offset: bestOffset, match: bestMatch)
    }

    private func evaluateSnap(
        source: CGRect,
        target: CGRect,
        proposed: CGPoint,
        edgeDelta: CGPoint,
        axisDelta: CGPoint,
        bestOffset: inout CGPoint,
        bestMatch: inout SnapMatch?,
        bestScore: inout CGFloat
    ) {
        let edgeDistance = abs(edgeDelta.x) + abs(edgeDelta.y)
        let axisDistance = abs(axisDelta.x) + abs(axisDelta.y)
        guard edgeDistance <= snapDistance, axisDistance <= snapDistance else { return }

        let candidateOffset = CGPoint(
            x: proposed.x + edgeDelta.x + axisDelta.x,
            y: proposed.y + edgeDelta.y + axisDelta.y
        )
        let snappedSource = source.offsetBy(dx: edgeDelta.x + axisDelta.x, dy: edgeDelta.y + axisDelta.y)
        guard rangesOverlap(snappedSource.minX, snappedSource.maxX, target.minX, target.maxX) ||
              rangesOverlap(snappedSource.minY, snappedSource.maxY, target.minY, target.maxY)
        else { return }

        let score = edgeDistance + axisDistance * 0.5
        if score < bestScore {
            bestScore = score
            bestOffset = candidateOffset
            bestMatch = SnapMatch(sourceFrame: snappedSource, targetFrame: target)
        }
    }

    private func verticalSnapDelta(_ source: CGRect, _ target: CGRect) -> CGPoint {
        let candidates = [
            target.minY - source.minY,
            target.maxY - source.maxY,
            target.midY - source.midY,
            CGFloat(0)
        ]
        let best = candidates.min { abs($0) < abs($1) } ?? 0
        return CGPoint(x: 0, y: abs(best) <= snapDistance ? best : 0)
    }

    private func horizontalSnapDelta(_ source: CGRect, _ target: CGRect) -> CGPoint {
        let candidates = [
            target.minX - source.minX,
            target.maxX - source.maxX,
            target.midX - source.midX,
            CGFloat(0)
        ]
        let best = candidates.min { abs($0) < abs($1) } ?? 0
        return CGPoint(x: abs(best) <= snapDistance ? best : 0, y: 0)
    }

    private func rangesOverlap(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> Bool {
        min(aMax, bMax) - max(aMin, bMin) > 1
    }

    private func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).size
        let point = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        attributed.draw(at: point)
    }

    private func drawText(_ text: String, at point: CGPoint, font: NSFont = .systemFont(ofSize: 13), color: NSColor = .secondaryLabelColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attrs)
    }
}

final class PortalServer {
    private var listener: NWListener?
    private var udpSocket: Int32 = -1
    private var udpThread: Thread?
    private var udpRunning = false
    private let networkQueue = DispatchQueue(label: "portal.network", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "portal.input", qos: .userInteractive)
    private let injector = InputInjector()
    private let liveStatsEnabled = false
    var motionProbe: MotionProbe?
    var onStatus: ((String) -> Void)?
    var onEvent: ((String) -> Void)?
    var onStats: ((String) -> Void)?
    var onRemoteDisplays: (([DisplayInfo]) -> Void)?
    var onClipboard: (([String: Any]) -> Void)?
    var onConnectionReady: (() -> Void)?
    var onReleaseFromWindows: ((Edge, Double, Double) -> Void)?
    var localDisplayProvider: (() -> [DisplayInfo])?
    var arrangementOffsetsProvider: (() -> [String: CGPoint])?
    var activationTargetProvider: ((Edge, Double, Double, DisplayInfo?) -> CGRect?)?
    var returnAllowedProvider: ((Edge, CGPoint) -> Bool)? {
        didSet { injector.returnAllowedProvider = returnAllowedProvider }
    }
    private var activeConnection: NWConnection?
    private var controllingWindows = false
    private var pendingRemoteDx = 0
    private var pendingRemoteDy = 0
    private var pendingRemoteRaw = 0
    private var remoteMoveTimer: DispatchSourceTimer?
    private var movePackets = 0
    private var rawMoves = 0
    private var buttons = 0
    private var keys = 0
    private var scrolls = 0
    private var statsWindowMoves = 0
    private var statsWindowRaw = 0
    private var lastStatsAt = Date()

    func start(port: UInt16, returnEdge: Edge) throws {
        injector.returnEdge = returnEdge
        startRemoteMoveTimer()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.onStatus?("Listening on port \(port)")
                case .failed(let error):
                    self?.onStatus?("Listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self?.onStatus?("Stopped")
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: networkQueue)

        try startUdpSocket(port: port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnection = nil
        controllingWindows = false
        stopRemoteMoveTimer()
        stopUdpSocket()
    }

    private func handle(_ connection: NWConnection) {
        activeConnection = connection
        injector.onReturnToWindows = { [weak connection] edge, xRatio, yRatio in
            Self.send([
                "type": "release",
                "edge": edge.rawValue,
                "xRatio": xRatio,
                "yRatio": yRatio
            ], on: connection)
        }

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.onStatus?("Windows connected")
                    self?.onConnectionReady?()
                    self?.sendLocalDisplayLayout()
                case .cancelled:
                    if let self, self.activeConnection === connection {
                        self.activeConnection = nil
                        self.controllingWindows = false
                        self.pendingRemoteDx = 0
                        self.pendingRemoteDy = 0
                        self.pendingRemoteRaw = 0
                    }
                    self?.onStatus?("Windows disconnected")
                case .failed(let error):
                    if let self, self.activeConnection === connection {
                        self.activeConnection = nil
                        self.controllingWindows = false
                        self.pendingRemoteDx = 0
                        self.pendingRemoteDy = 0
                        self.pendingRemoteRaw = 0
                    }
                    self?.onStatus?("Connection failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            while let newline = nextBuffer.firstIndex(of: 10) {
                let line = nextBuffer.prefix(upTo: newline)
                nextBuffer.removeSubrange(...newline)
                self?.handleLine(Data(line))
            }
            self?.receive(on: connection, buffer: nextBuffer)
        }
    }

    private func startUdpSocket(port: UInt16) throws {
        stopUdpSocket()

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var receiveBuffer: Int32 = 1_048_576
        _ = withUnsafePointer(to: &receiveBuffer) {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let error = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }

        udpSocket = fd
        udpRunning = true
        let thread = Thread { [weak self] in
            self?.udpSocketLoop(fd: fd)
        }
        thread.name = "portal.udp.socket"
        thread.threadPriority = 1.0
        udpThread = thread
        thread.start()
    }

    private func stopUdpSocket() {
        udpRunning = false
        if udpSocket >= 0 {
            Darwin.close(udpSocket)
            udpSocket = -1
        }
        udpThread = nil
    }

    private func udpSocketLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64)
        while udpRunning {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }

            if count > 0 {
                let data = Data(buffer.prefix(count))
                if let move = parseUdpMove(data) {
                    enqueueMove(dx: move.dx, dy: move.dy, raw: move.raw)
                    recordMove(raw: move.raw, dx: move.dx, dy: move.dy, senderGapMs: move.senderGapMs, sequence: move.sequence)
                }
            } else if udpRunning && errno != EINTR {
                usleep(1_000)
            }
        }
    }

    private func enqueueMove(dx: Int, dy: Int, raw _: Int) {
        inputQueue.async { [weak self] in
            self?.injector.move(dx: dx, dy: dy)
        }
    }

    private func handleLine(_ data: Data) {
        if data.first == 109, let move = parseMoveLine(data) {
            enqueueMove(dx: move.dx, dy: move.dy, raw: move.raw)
            recordMove(raw: move.raw, dx: move.dx, dy: move.dy)
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "release":
            let edge = (obj["edge"] as? String).flatMap(Edge.init(rawValue:)) ?? .left
            let xRatio = obj["xRatio"] as? Double ?? 0.5
            let yRatio = obj["yRatio"] as? Double ?? 0.5
            controllingWindows = false
            DispatchQueue.main.async { [weak self] in
                self?.onReleaseFromWindows?(edge, xRatio, yRatio)
            }
        case "activate":
            if let edgeName = obj["edge"] as? String,
               let edge = Edge(rawValue: edgeName) {
                recordEvent("activate \(edgeName)")
                let yRatio = obj["yRatio"] as? Double ?? 0.5
                let xRatio = obj["xRatio"] as? Double ?? 0.5
                let sourceDisplay = (obj["screen"] as? [String: Any]).flatMap(Self.parseDisplayInfo)
                var targetFrame: CGRect?
                var shouldActivate = true
                if let activationTargetProvider {
                    if Thread.isMainThread {
                        targetFrame = activationTargetProvider(edge, xRatio, yRatio, sourceDisplay)
                    } else {
                        DispatchQueue.main.sync {
                            targetFrame = activationTargetProvider(edge, xRatio, yRatio, sourceDisplay)
                        }
                    }
                    shouldActivate = sourceDisplay == nil || targetFrame != nil
                }
                guard shouldActivate else {
                    recordEvent("activate rejected by arrangement")
                    return
                }
                inputQueue.async { [weak self] in
                    guard let self else { return }
                    self.injector.returnEdge = edge.opposite
                    self.recordEvent("return edge \(edge.opposite.rawValue)")
                    self.injector.activate(from: edge, yRatio: yRatio, xRatio: xRatio, targetFrame: targetFrame)
                }
            }
        case "move":
            let dx = obj["dx"] as? Int ?? 0
            let dy = obj["dy"] as? Int ?? 0
            let raw = obj["raw"] as? Int ?? 1
            enqueueMove(dx: dx, dy: dy, raw: raw)
            recordMove(raw: raw, dx: dx, dy: dy)
        case "button":
            buttons += ((obj["down"] as? Bool) == true ? 1 : 0)
            recordEvent("button \(obj["button"] as? String ?? "left")")
            let buttonName = obj["button"] as? String ?? "left"
            let down = obj["down"] as? Bool ?? false
            inputQueue.async { [weak self] in
                self?.injector.button(name: buttonName, down: down)
            }
        case "scroll":
            scrolls += 1
            recordEvent("scroll")
            let dx = obj["dx"] as? Int ?? 0
            let dy = obj["dy"] as? Int ?? 0
            inputQueue.async { [weak self] in
                self?.injector.scroll(dx: dx, dy: dy)
            }
        case "key":
            keys += ((obj["down"] as? Bool) == true ? 1 : 0)
            let keyName = obj["key"] as? String ?? ""
            let text = obj["text"] as? String
            let layout = obj["layout"] as? String ?? ""
            let ctrl = obj["ctrl"] as? Bool ?? false
            let alt = obj["alt"] as? Bool ?? false
            recordEvent("key \(keyName) \(text ?? "") \(layout)")
            let down = obj["down"] as? Bool ?? false
            inputQueue.async { [weak self] in
                self?.injector.key(name: keyName, down: down, text: text, ctrl: ctrl, alt: alt)
            }
        case "displayLayout":
            guard let displays = Self.parseDisplayLayout(obj) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onRemoteDisplays?(displays)
            }
        case "clipboard":
            DispatchQueue.main.async { [weak self] in
                self?.onClipboard?(obj)
            }
        default:
            break
        }
    }

    private func receiveUdp(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard error == nil, let connection else {
                connection?.cancel()
                return
            }
            if let data, let move = self?.parseUdpMove(data) {
                self?.enqueueMove(dx: move.dx, dy: move.dy, raw: move.raw)
                self?.recordMove(raw: move.raw, dx: move.dx, dy: move.dy, senderGapMs: move.senderGapMs, sequence: move.sequence)
            }
            self?.receiveUdp(on: connection)
        }
    }

    private func parseUdpMove(_ data: Data) -> (dx: Int, dy: Int, raw: Int, senderGapMs: Double, sequence: Int?)? {
        guard data.count >= 13, data[data.startIndex] == 77 else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }

            func readInt32(_ offset: Int) -> Int {
                let value = UInt32(base[offset])
                    | (UInt32(base[offset + 1]) << 8)
                    | (UInt32(base[offset + 2]) << 16)
                    | (UInt32(base[offset + 3]) << 24)
                return Int(Int32(bitPattern: value))
            }

            let dx = readInt32(1)
            let dy = readInt32(5)
            let raw = max(readInt32(9), 1)
            if data.count >= 21 {
                let sequence = readInt32(13)
                let senderGapMs = Double(max(readInt32(17), 0)) / 1000.0
                return (dx, dy, raw, senderGapMs, sequence)
            }
            return (dx, dy, raw, 0, nil)
        }
    }

    private func parseMoveLine(_ data: Data) -> (dx: Int, dy: Int, raw: Int)? {
        var values: [Int] = []
        values.reserveCapacity(3)
        var sign = 1
        var value = 0
        var inNumber = false

        func finishNumber() {
            guard inNumber else { return }
            values.append(sign * value)
            sign = 1
            value = 0
            inNumber = false
        }

        for byte in data.dropFirst() {
            if byte == 45 {
                if !inNumber {
                    sign = -1
                    inNumber = true
                    value = 0
                } else {
                    finishNumber()
                    sign = -1
                    inNumber = true
                }
            } else if byte >= 48 && byte <= 57 {
                if !inNumber {
                    sign = 1
                    value = 0
                    inNumber = true
                }
                value = value * 10 + Int(byte - 48)
            } else {
                finishNumber()
            }
        }
        finishNumber()

        guard values.count >= 3 else { return nil }
        return (values[0], values[1], max(values[2], 1))
    }

    private func recordMove(raw: Int, dx: Int, dy: Int, senderGapMs: Double = 0, sequence: Int? = nil) {
        motionProbe?.record(dx: dx, dy: dy, raw: raw, senderGapMs: senderGapMs, sequence: sequence)
        movePackets += 1
        rawMoves += max(raw, 1)
        if liveStatsEnabled {
            statsWindowMoves += 1
            statsWindowRaw += max(raw, 1)
            maybePublishStats(lastEvent: "move \(dx),\(dy)")
        }
    }

    private func recordEvent(_ event: String) {
        maybePublishStats(lastEvent: event, force: true)
    }

    private func maybePublishStats(lastEvent: String, force: Bool = false) {
        guard liveStatsEnabled || force else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStatsAt) >= 1.0 else { return }
        let elapsed = max(now.timeIntervalSince(lastStatsAt), 0.001)
        let moveRate = Double(statsWindowMoves) / elapsed
        let rawRate = Double(statsWindowRaw) / elapsed
        let stats = String(
            format: "%.0f pkt/s · %.0f raw/s · moves %d/%d · clicks %d · keys %d · scrolls %d · %@",
            moveRate,
            rawRate,
            movePackets,
            rawMoves,
            buttons,
            keys,
            scrolls,
            lastEvent
        )
        statsWindowMoves = 0
        statsWindowRaw = 0
        lastStatsAt = now
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(stats)
        }
    }

    func testMove() {
        injector.testMove()
    }

    func testClick() {
        injector.testClick()
    }

    func sendLocalDisplayLayout() {
        guard let activeConnection,
              let displays = localDisplayProvider?()
        else { return }
        var payload = Self.displayLayoutPayload(platform: "mac", displays: displays)
        let offsets = arrangementOffsetsProvider?() ?? [:]
        payload["machineOffsets"] = offsets.mapValues { point in
            ["x": Double(point.x), "y": Double(point.y)]
        }
        Self.send(payload, on: activeConnection)
    }

    func activateWindows(edge: Edge, xRatio: Double, yRatio: Double, sourceDisplay: DisplayInfo) {
        guard let activeConnection else { return }
        controllingWindows = true
        Self.send([
            "type": "activate",
            "edge": edge.rawValue,
            "xRatio": xRatio,
            "yRatio": yRatio,
            "screen": Self.displayPayload(sourceDisplay)
        ], on: activeConnection)
    }

    func sendRemoteMove(dx: Int, dy: Int) {
        guard controllingWindows else { return }
        networkQueue.async { [weak self] in
            guard let self, self.controllingWindows else { return }
            self.pendingRemoteDx += dx
            self.pendingRemoteDy += dy
            self.pendingRemoteRaw += 1
        }
    }

    func sendRemoteButton(name: String, down: Bool) {
        guard controllingWindows else { return }
        Self.send(["type": "button", "button": name, "down": down], on: activeConnection)
    }

    func sendRemoteScroll(dx: Int, dy: Int) {
        guard controllingWindows else { return }
        Self.send(["type": "scroll", "dx": dx, "dy": dy], on: activeConnection)
    }

    func sendRemoteKey(name: String, down: Bool) {
        guard controllingWindows else { return }
        Self.send(["type": "key", "key": name, "down": down], on: activeConnection)
    }

    var canControlWindows: Bool {
        activeConnection != nil
    }

    private func startRemoteMoveTimer() {
        guard remoteMoveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.flushRemoteMoves()
        }
        remoteMoveTimer = timer
        timer.resume()
    }

    private func stopRemoteMoveTimer() {
        remoteMoveTimer?.cancel()
        remoteMoveTimer = nil
    }

    private func flushRemoteMoves() {
        guard controllingWindows, let connection = activeConnection else { return }
        let dx = pendingRemoteDx
        let dy = pendingRemoteDy
        let raw = pendingRemoteRaw
        if dx == 0, dy == 0 { return }
        pendingRemoteDx = 0
        pendingRemoteDy = 0
        pendingRemoteRaw = 0
        let line = "m \(dx) \(dy) \(max(raw, 1))\n"
        connection.send(content: line.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    func sendClipboard(_ payload: [String: Any]) -> Bool {
        guard let activeConnection else { return false }
        return Self.send(payload, on: activeConnection)
    }

    private static func displayLayoutPayload(platform: String, displays: [DisplayInfo]) -> [String: Any] {
        [
            "type": "displayLayout",
            "platform": platform,
            "displays": displays.map { display in
                [
                    "name": display.name,
                    "x": Int(display.frame.minX.rounded()),
                    "y": Int(display.frame.minY.rounded()),
                    "width": Int(display.frame.width.rounded()),
                    "height": Int(display.frame.height.rounded()),
                    "primary": display.isPrimary
                ] as [String: Any]
            }
        ]
    }

    private static func displayPayload(_ display: DisplayInfo) -> [String: Any] {
        [
            "name": display.name,
            "x": Double(display.frame.minX),
            "y": Double(display.frame.minY),
            "width": Double(display.frame.width),
            "height": Double(display.frame.height),
            "primary": display.isPrimary
        ]
    }

    private static func parseDisplayLayout(_ obj: [String: Any]) -> [DisplayInfo]? {
        guard let rawDisplays = obj["displays"] as? [[String: Any]] else { return nil }
        let displays = rawDisplays.compactMap(Self.parseDisplayInfo)
        return displays.isEmpty ? nil : displays
    }

    private static func parseDisplayInfo(_ raw: [String: Any]) -> DisplayInfo? {
        guard let width = doubleValue(raw["width"]),
              let height = doubleValue(raw["height"]),
              width > 0,
              height > 0
        else { return nil }

        let name = raw["name"] as? String ?? "Display"
        let x = doubleValue(raw["x"]) ?? 0
        let y = doubleValue(raw["y"]) ?? 0
        let primary = (raw["primary"] as? Bool) ?? false
        return DisplayInfo(
            name: name,
            frame: CGRect(x: x, y: y, width: width, height: height),
            isPrimary: primary
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    @discardableResult
    private static func send(_ payload: [String: Any], on connection: NWConnection?) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let newline = "\n".data(using: .utf8)
        else { return false }
        connection?.send(content: data + newline, completion: .contentProcessed { _ in })
        return connection != nil
    }
}

final class MacBeaconBroadcaster {
    private let discoveryPort: UInt16
    private let queue = DispatchQueue(label: "portal.mac.beacon", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var serverPort: UInt16 = 45877
    private var addressesProvider: (() -> [String])?

    init(discoveryPort: UInt16) {
        self.discoveryPort = discoveryPort
    }

    func start(serverPort: UInt16, addressesProvider: @escaping () -> [String]) {
        self.serverPort = serverPort
        self.addressesProvider = addressesProvider
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.broadcast()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func broadcast() {
        guard let addresses = addressesProvider?(), !addresses.isEmpty else { return }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }

        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) {
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = discoveryPort.bigEndian
        target.sin_addr = in_addr(s_addr: INADDR_BROADCAST.bigEndian)

        for ip in addresses {
            guard let payload = try? JSONSerialization.data(withJSONObject: [
                "type": "portalMacBeacon",
                "ip": ip,
                "port": Int(serverPort)
            ]) else { continue }

            payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        _ = Darwin.sendto(fd, baseAddress, payload.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }
}

private struct ClipboardSnapshot {
    let id: String
    let contentType: String
    let text: String?
    let dataBase64: String?
    let byteCount: Int
    let signature: String

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "type": "clipboard",
            "id": id,
            "contentType": contentType,
            "byteCount": byteCount
        ]
        if let text {
            payload["text"] = text
        }
        if let dataBase64 {
            payload["data"] = dataBase64
        }
        return payload
    }
}

final class ClipboardBridge {
    private let maxImageBytes = 8 * 1024 * 1024
    private let logURL = URL(fileURLWithPath: "/tmp/portal-clipboard.log")
    private var timer: Timer?
    private var lastChangeCount = -1
    private var lastLocalSignature: String?
    private var lastAppliedSignature: String?
    private var sendPayload: (([String: Any]) -> Bool)?
    private var publishStatus: ((String) -> Void)?

    func start(send: @escaping ([String: Any]) -> Bool, status: @escaping (String) -> Void) {
        sendPayload = send
        publishStatus = status
        status("Clipboard: text and images ready")
        log("bridge start")
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.pollLocalClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func republishCurrentClipboard() {
        lastChangeCount = -1
        log("republish current clipboard")
        pollLocalClipboard()
    }

    func applyRemotePayload(_ payload: [String: Any]) {
        guard let contentType = payload["contentType"] as? String else { return }
        let text = payload["text"] as? String
        let dataBase64 = payload["data"] as? String
        guard contentType == "text/plain" || contentType == "image/png" else { return }

        let signature = Self.signature(contentType: contentType, text: text, dataBase64: dataBase64)
        if signature == lastLocalSignature || signature == lastAppliedSignature { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch contentType {
        case "text/plain":
            guard let text else { return }
            pasteboard.setString(text, forType: .string)
            log("received text bytes=\(text.utf8.count)")
            publishStatus?("Clipboard: received text")
        case "image/png":
            guard let dataBase64,
                  let data = Data(base64Encoded: dataBase64),
                  data.count <= maxImageBytes
            else { return }
            pasteboard.setData(data, forType: .png)
            if let image = NSImage(data: data),
               let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            log("received image bytes=\(data.count)")
            publishStatus?("Clipboard: received image")
        default:
            return
        }

        lastAppliedSignature = signature
        lastLocalSignature = signature
        lastChangeCount = pasteboard.changeCount
    }

    private func pollLocalClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        log("change count \(lastChangeCount)")

        guard let snapshot = readLocalClipboard(from: pasteboard) else {
            log("no supported local clipboard item")
            return
        }
        if snapshot.signature == lastLocalSignature || snapshot.signature == lastAppliedSignature {
            log("skip duplicate \(snapshot.contentType)")
            return
        }

        if snapshot.byteCount > maxImageBytes {
            lastLocalSignature = snapshot.signature
            log("skip oversized \(snapshot.byteCount)")
            publishStatus?("Clipboard: image too large")
            return
        }

        let sent = sendPayload?(snapshot.payload) == true
        log("send \(snapshot.contentType) bytes=\(snapshot.byteCount) result=\(sent)")
        if sent {
            lastLocalSignature = snapshot.signature
            publishStatus?(snapshot.contentType == "text/plain" ? "Clipboard: sent text" : "Clipboard: sent image")
        }
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private func readLocalClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        if let imageData = imagePNGData(from: pasteboard) {
            let dataBase64 = imageData.base64EncodedString()
            let signature = Self.signature(contentType: "image/png", text: nil, dataBase64: dataBase64)
            return ClipboardSnapshot(
                id: UUID().uuidString,
                contentType: "image/png",
                text: nil,
                dataBase64: dataBase64,
                byteCount: imageData.count,
                signature: signature
            )
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        let signature = Self.signature(contentType: "text/plain", text: text, dataBase64: nil)
        return ClipboardSnapshot(
            id: UUID().uuidString,
            contentType: "text/plain",
            text: text,
            dataBase64: nil,
            byteCount: text.lengthOfBytes(using: .utf8),
            signature: signature
        )
    }

    private func imagePNGData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiff) {
            return Self.pngData(from: image)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return Self.pngData(from: image)
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func signature(contentType: String, text: String?, dataBase64: String?) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        for byte in contentType.utf8 { mix(byte) }
        mix(0)
        if let text {
            for byte in text.utf8 { mix(byte) }
        }
        if let dataBase64 {
            for byte in dataBase64.utf8 { mix(byte) }
        }
        return String(format: "%016llx", hash)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bidirectionalWindowsControlEnabled = false
    private let server = PortalServer()
    private let localInputForwarder = LocalInputForwarder()
    private let macBeaconBroadcaster = MacBeaconBroadcaster(discoveryPort: 45878)
    private let clipboardBridge = ClipboardBridge()
    private let motionProbe = MotionProbe()
    private var motionLogWriter: MotionLogWriter?
    private var realtimeActivity: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var statusStartStopItem: NSMenuItem?
    private var window: NSWindow!
    private let portField = NSTextField(string: "45877")
    private let edgePopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "Stopped")
    private let ipLabel = NSTextField(labelWithString: "IP: checking...")
    private let displayLabel = NSTextField(labelWithString: "Displays: checking...")
    private let permissionLabel = NSTextField(labelWithString: "Accessibility: use the enabled switch in System Settings")
    private let awdlLabel = NSTextField(labelWithString: "Low latency: checking...")
    private let clipboardLabel = NSTextField(labelWithString: "Clipboard: starting...")
    private let awdlSwitch = NSSwitch()
    private let settingsButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    private let eventLabel = NSTextField(labelWithString: "Stats: idle")
    private let motionGraph = MotionGraphView()
    private let uiModel = PortalUIModel()
    private let arrangementView = DisplayArrangementView()
    private let arrangementLabel = NSTextField(labelWithString: "Arrangement: checking...")
    private let resetArrangementButton = NSButton(title: "Reset Arrangement", target: nil, action: nil)
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private var running = false
    private var eventCount = 0
    private var starting = false
    private var autoStarted = false
    private var remoteWindowsDisplays: [DisplayInfo] = []
    private var machineOffsets: [String: CGPoint] = [:]
    private var accessibilityTimer: Timer?
    private var networkTimer: Timer?
    private var installerServerProcess: Process?
    private let installerPort = 8123

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        realtimeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInteractive, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Portal realtime mouse and keyboard sharing"
        )
        server.motionProbe = motionProbe
        motionLogWriter = MotionLogWriter(probe: motionProbe)
        machineOffsets = loadMachineOffsets()
        arrangementView.machineOffsets = machineOffsets
        arrangementView.onOffsetsChanged = { [weak self] offsets in
            self?.machineOffsets = offsets
            self?.saveMachineOffsets(offsets)
            self?.server.sendLocalDisplayLayout()
        }
        buildWindow()
        showPortalWindow()
        buildStatusItem()
        server.onStatus = { [weak self] status in self?.setStatus(status) }
        server.onEvent = { [weak self] event in self?.recordEvent(event) }
        server.onStats = { [weak self] stats in
            self?.eventLabel.stringValue = stats
            self?.uiModel.stats = stats
        }
        server.localDisplayProvider = { [weak self] in self?.displayInfos() ?? [] }
        server.arrangementOffsetsProvider = { [weak self] in self?.machineOffsets ?? [:] }
        server.activationTargetProvider = { [weak self] edge, xRatio, yRatio, sourceDisplay in
            self?.resolveActivationTarget(edge: edge, xRatio: xRatio, yRatio: yRatio, sourceDisplay: sourceDisplay)
        }
        server.returnAllowedProvider = { [weak self] edge, point in
            self?.arrangementAllowsReturn(edge: edge, point: point) ?? false
        }
        server.onRemoteDisplays = { [weak self] displays in
            self?.remoteWindowsDisplays = displays
            self?.refreshDisplayLabel()
        }
        server.onClipboard = { [weak self] payload in
            self?.clipboardBridge.applyRemotePayload(payload)
        }
        server.onConnectionReady = { [weak self] in
            self?.clipboardBridge.republishCurrentClipboard()
        }
        if bidirectionalWindowsControlEnabled {
            server.onReleaseFromWindows = { [weak self] edge, xRatio, yRatio in
                self?.localInputForwarder.finishControlFromWindows(edge: edge, xRatio: xRatio, yRatio: yRatio)
                self?.recordEvent("release \(edge.rawValue)")
            }
            localInputForwarder.activationProvider = { [weak self] point in
                self?.activationForWindows(at: point)
            }
            localInputForwarder.onActivate = { [weak self] activation in
                self?.recordEvent("activate windows \(activation.edge.rawValue)")
                self?.server.activateWindows(edge: activation.edge, xRatio: activation.xRatio, yRatio: activation.yRatio, sourceDisplay: activation.display)
            }
            localInputForwarder.onMove = { [weak self] dx, dy in
                self?.server.sendRemoteMove(dx: dx, dy: dy)
            }
            localInputForwarder.onButton = { [weak self] name, down in
                self?.server.sendRemoteButton(name: name, down: down)
            }
            localInputForwarder.onScroll = { [weak self] dx, dy in
                self?.server.sendRemoteScroll(dx: dx, dy: dy)
            }
            localInputForwarder.onKey = { [weak self] name, down in
                self?.server.sendRemoteKey(name: name, down: down)
            }
            localInputForwarder.start()
        }
        clipboardBridge.start(
            send: { [weak self] payload in self?.server.sendClipboard(payload) ?? false },
            status: { [weak self] status in self?.clipboardLabel.stringValue = status }
        )
        eventLabel.stringValue = "Stats: idle"
        DispatchQueue.main.async { [weak self] in
            self?.autoStartOnce()
        }
        refreshAccessibilityStatus()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityStatus()
        }
        refreshNetworkStatus()
        refreshDisplayLabel()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            if self?.running == true && self?.uiModel.awdlEnabled == false {
                _ = self?.setAwdlSync(enabled: false)
            }
            self?.refreshNetworkStatus()
            self?.refreshDisplayLabel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkTimer?.invalidate()
        accessibilityTimer?.invalidate()
        if bidirectionalWindowsControlEnabled {
            localInputForwarder.stop()
        }
        macBeaconBroadcaster.stop()
        stopInstallerServer()
        clipboardBridge.stop()
        server.stop()
        setAwdlSync(enabled: true)
        if let realtimeActivity {
            ProcessInfo.processInfo.endActivity(realtimeActivity)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPortalWindow()
        }
        return true
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Portal"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.maxSize = NSSize(width: 860, height: 560)
        window.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        positionWindowOnMainScreen()
        motionGraph.probe = motionProbe
        uiModel.port = portField.stringValue
        uiModel.edge = Edge(rawValue: edgePopup.titleOfSelectedItem ?? "right") ?? .right
        let rootView = PortalRootView(
            model: uiModel,
            motionGraph: motionGraph,
            arrangementView: arrangementView,
            toggleServer: { [weak self] in self?.toggleServer() },
            toggleAwdl: { [weak self] enabled in self?.setAwdl(enabled: enabled, promptIfNeeded: true) },
            openAccessibility: { [weak self] in self?.openAccessibilitySettings() },
            resetArrangement: { [weak self] in self?.resetArrangement() },
            scanWindowsHosts: { [weak self] in self?.scanWindowsHosts() },
            toggleInstallerServer: { [weak self] in self?.toggleInstallerServer() },
            copyWindowsInstallCommand: { [weak self] in self?.copyWindowsInstallCommand() }
        )
        window.contentView = NSHostingView(rootView: rootView)
        refreshIpLabel()
        refreshDisplayLabel()
    }

    private func positionWindowOnMainScreen() {
        let primaryScreen = NSScreen.screens.max {
            ($0.visibleFrame.width * $0.visibleFrame.height) < ($1.visibleFrame.width * $1.visibleFrame.height)
        } ?? NSScreen.main
        guard let screen = primaryScreen else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "Portal") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Portal"
            }
            button.toolTip = "Portal"
        }

        let menu = NSMenu()
        let status = NSMenuItem(title: "Status: \(statusLabel.stringValue)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "Show Portal", action: #selector(showPortalWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let startStop = NSMenuItem(title: running ? "Stop" : "Start", action: #selector(toggleServer(_:)), keyEquivalent: "")
        startStop.target = self
        statusStartStopItem = startStop
        menu.addItem(startStop)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Portal", action: #selector(quitPortal), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateStatusMenu()
    }

    private func row(label: String, control: NSView) -> NSView {
        let view = NSStackView()
        view.orientation = .horizontal
        view.alignment = .firstBaseline
        view.spacing = 18
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .boldSystemFont(ofSize: 13)
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        view.addArrangedSubview(labelView)
        view.addArrangedSubview(control)
        return view
    }

    @objc private func toggleServer(_ sender: Any?) {
        guard sender is NSButton || sender is NSMenuItem else { return }
        toggleServer()
    }

    private func toggleServer() {
        if starting { return }
        if running {
            macBeaconBroadcaster.stop()
            server.stop()
            running = false
            updateRunningControls()
            setStatus("Stopped")
            setAwdl(enabled: true, promptIfNeeded: false)
            return
        }

        guard let port = UInt16(uiModel.port) else {
            setStatus("Invalid port")
            return
        }
        refreshAccessibilityStatus()
        let edge = uiModel.edge
        starting = true
        statusStartStopItem?.isEnabled = false
        uiModel.isStarting = true
        setStatus("Preparing low latency...")
        ensureAwdlSudoersReady { [weak self] ready in
            guard let self else { return }
            if !ready {
                self.starting = false
                self.statusStartStopItem?.isEnabled = true
                self.uiModel.isStarting = false
                self.setStatus("Start cancelled: AWDL permission not installed")
                self.refreshNetworkStatus()
                return
            }

            _ = self.setAwdlSync(enabled: false)
            self.refreshNetworkStatus()
            self.startServer(port: port, edge: edge)
        }
    }

    private func startServer(port: UInt16, edge: Edge) {
        do {
            try server.start(port: port, returnEdge: edge)
            running = true
            macBeaconBroadcaster.start(serverPort: port) { [weak self] in
                guard let self, let preferred = self.preferredLocalIPv4Address() else { return [] }
                return [preferred]
            }
            updateRunningControls()
        } catch {
            setStatus("Start failed: \(error.localizedDescription)")
            _ = setAwdlSync(enabled: true)
            refreshNetworkStatus()
        }
        starting = false
        statusStartStopItem?.isEnabled = true
        uiModel.isStarting = false
    }

    @objc private func showPortalWindow() {
        positionWindowOnMainScreen()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    @objc private func quitPortal() {
        NSApp.terminate(nil)
    }

    private func setStatus(_ status: String) {
        statusLabel.stringValue = status
        uiModel.status = status
        updateStatusMenu()
    }

    private func updateRunningControls() {
        startButton.title = running ? "Stop" : "Start"
        uiModel.isRunning = running
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        statusMenuItem?.title = "Status: \(statusLabel.stringValue)"
        statusStartStopItem?.title = running ? "Stop" : "Start"
        statusItem?.button?.toolTip = "Portal - \(statusLabel.stringValue)"
    }

    private func autoStartOnce() {
        if autoStarted { return }
        autoStarted = true
        if !running {
            toggleServer()
        }
    }

    private func requestAccessibilityIfNeeded() {
        permissionLabel.stringValue = "Accessibility: use the enabled switch in System Settings"
        permissionLabel.textColor = .secondaryLabelColor
        uiModel.accessibility = permissionLabel.stringValue
        uiModel.accessibilityOK = false
        settingsButton.isHidden = false
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshAccessibilityStatus()
        }
    }

    @objc private func toggleAwdlSwitch() {
        setAwdl(enabled: uiModel.awdlEnabled, promptIfNeeded: true)
    }

    @objc private func testMove() {
        server.testMove()
        recordEvent("local test move")
    }

    @objc private func testClick() {
        server.testClick()
        recordEvent("local test click")
    }

    @objc private func resetArrangement() {
        machineOffsets = [:]
        saveMachineOffsets(machineOffsets)
        arrangementView.machineOffsets = machineOffsets
        arrangementView.resetViewport()
        refreshDisplayLabel()
    }

    private func recordEvent(_ event: String) {
        eventCount += 1
        eventLabel.stringValue = "Events \(eventCount) · \(event)"
        uiModel.stats = eventLabel.stringValue
    }

    private func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = trusted ? "Accessibility: granted" : "Accessibility: not trusted - click/keyboard will not work"
        permissionLabel.textColor = trusted ? .systemGreen : .systemOrange
        uiModel.accessibility = permissionLabel.stringValue
        uiModel.accessibilityOK = trusted
        settingsButton.isHidden = false
        if trusted {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
        }
    }

    private func refreshNetworkStatus() {
        switch awdlIsUp() {
        case true:
            awdlLabel.stringValue = "Enabled - cursor may stutter on Wi-Fi"
            awdlLabel.textColor = .systemOrange
            awdlSwitch.state = .on
            awdlSwitch.isEnabled = true
            uiModel.awdlEnabled = true
            uiModel.awdlText = awdlLabel.stringValue
            uiModel.awdlColor = .portalOrange
        case false:
            awdlLabel.stringValue = "Disabled - low latency mode"
            awdlLabel.textColor = .systemGreen
            awdlSwitch.state = .off
            awdlSwitch.isEnabled = true
            uiModel.awdlEnabled = false
            uiModel.awdlText = awdlLabel.stringValue
            uiModel.awdlColor = .portalGreen
        case nil:
            awdlLabel.stringValue = "Low latency: AWDL interface not found"
            awdlLabel.textColor = .secondaryLabelColor
            awdlSwitch.state = .off
            awdlSwitch.isEnabled = false
            uiModel.awdlEnabled = false
            uiModel.awdlText = awdlLabel.stringValue
            uiModel.awdlColor = .secondary
        }
    }

    private func setAwdl(enabled: Bool, promptIfNeeded: Bool, completion: ((Bool) -> Void)? = nil) {
        awdlSwitch.isEnabled = false
        awdlLabel.stringValue = enabled ? "Enabling AWDL..." : "Disabling AWDL..."
        awdlLabel.textColor = .secondaryLabelColor
        uiModel.awdlEnabled = enabled
        uiModel.awdlText = awdlLabel.stringValue
        uiModel.awdlColor = .secondary

        let action = enabled ? "up" : "down"
        let sudoProcess = Process()
        sudoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudoProcess.arguments = ["-n", "/sbin/ifconfig", "awdl0", action]
        sudoProcess.terminationHandler = { [weak self] process in
            if process.terminationStatus == 0 {
                DispatchQueue.main.async {
                    self?.refreshNetworkStatus()
                    completion?(true)
                }
            } else if promptIfNeeded {
                DispatchQueue.main.async {
                    self?.setAwdlWithAdminPrompt(enabled: enabled, completion: completion)
                }
            } else {
                DispatchQueue.main.async {
                    self?.refreshNetworkStatus()
                    completion?(false)
                }
            }
        }

        do {
            try sudoProcess.run()
        } catch {
            if promptIfNeeded {
                setAwdlWithAdminPrompt(enabled: enabled, completion: completion)
            } else {
                refreshNetworkStatus()
                completion?(false)
            }
        }
    }

    private func setAwdlWithAdminPrompt(enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        let command = enabled ? "/sbin/ifconfig awdl0 up" : "/sbin/ifconfig awdl0 down"
        let script = "do shell script \"\(command)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                if process.terminationStatus != 0 {
                    self?.awdlLabel.stringValue = "Low latency: admin action cancelled or failed"
                    self?.awdlLabel.textColor = .systemOrange
                }
                self?.refreshNetworkStatus()
                completion?(process.terminationStatus == 0)
            }
        }

        do {
            try process.run()
        } catch {
            awdlLabel.stringValue = "Low latency: failed to run admin action"
            awdlLabel.textColor = .systemOrange
            refreshNetworkStatus()
            completion?(false)
        }
    }

    @discardableResult
    private func setAwdlSync(enabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/sbin/ifconfig", "awdl0", enabled ? "up" : "down"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func ensureAwdlSudoersReady(completion: @escaping (Bool) -> Void) {
        if awdlSudoersReady() {
            completion(true)
            return
        }

        awdlLabel.stringValue = "Low latency: one-time admin permission required"
        awdlLabel.textColor = .systemOrange
        uiModel.awdlText = awdlLabel.stringValue
        uiModel.awdlColor = .portalOrange
        installAwdlSudoers { [weak self] installed in
            DispatchQueue.main.async {
                let ready = installed && (self?.awdlSudoersReady() ?? false)
                completion(ready)
            }
        }
    }

    private func awdlSudoersReady() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/sbin/ifconfig", "awdl0", "down"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func installAwdlSudoers(completion: @escaping (Bool) -> Void) {
        let command = """
        USER_NAME=$(stat -f '%Su' /dev/console); \
        if [ -z "$USER_NAME" ] || [ "$USER_NAME" = root ]; then exit 1; fi; \
        TMP_FILE=$(mktemp); \
        printf '%s\\n' '# Allow Portal to toggle only the AWDL interface without prompting every time.' "$USER_NAME ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up" > "$TMP_FILE"; \
        chown root:wheel "$TMP_FILE"; \
        chmod 440 "$TMP_FILE"; \
        visudo -cf "$TMP_FILE" >/dev/null; \
        cp "$TMP_FILE" /etc/sudoers.d/portal-awdl; \
        rm -f "$TMP_FILE"
        """
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.terminationHandler = { process in
            completion(process.terminationStatus == 0)
        }

        do {
            try process.run()
        } catch {
            completion(false)
        }
    }

    private func awdlIsUp() -> Bool? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "awdl0" else { continue }
            let flags = Int32(item.pointee.ifa_flags)
            return flags & IFF_UP != 0
        }
        return nil
    }

    private func scanWindowsHosts() {
        if uiModel.isScanningWindows { return }
        guard let localIP = preferredLocalIPv4Address(),
              let subnet = subnetPrefix(for: localIP)
        else {
            uiModel.windowsSetupStatus = "No LAN IP found for scanning"
            return
        }

        uiModel.isScanningWindows = true
        uiModel.windowsSetupStatus = "Scanning \(subnet).0/24..."
        let script = """
        subnet="$1"
        count=0
        for n in $(seq 1 254); do
          host="$subnet.$n"
          (
            ping -q -c 1 -W 200 "$host" >/dev/null 2>&1 || exit 0
            ports=""
            for port in 22 445 3389; do
              if nc -G 1 -z "$host" "$port" >/dev/null 2>&1; then
                ports="${ports}${ports:+,}$port"
              fi
            done
            if [ -n "$ports" ]; then
              name="$(dig +short -x "$host" 2>/dev/null | sed 's/\\.$//' | head -1)"
              printf '%s|%s|%s\\n' "$host" "$ports" "$name"
            fi
          ) &
          count=$((count + 1))
          if [ $((count % 32)) -eq 0 ]; then
            wait
          fi
        done
        wait
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hosts = self?.runWindowsScanScript(script: script, subnet: subnet) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.uiModel.windowsHosts = hosts
                self.uiModel.isScanningWindows = false
                if hosts.isEmpty {
                    self.uiModel.windowsSetupStatus = "No Windows candidates found"
                } else {
                    let sshReady = hosts.filter { $0.ports.contains("22") }.count
                    self.uiModel.windowsSetupStatus = sshReady > 0 ? "\(hosts.count) hosts found, \(sshReady) ready for remote install" : "\(hosts.count) hosts found, use installer sharing first"
                }
            }
        }
    }

    private func runWindowsScanScript(script: String, subnet: String) -> [WindowsHostCandidate] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", script, "portal-scan", subnet]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let raw = String(data: data, encoding: .utf8) else { return [] }
            return raw
                .split(separator: "\n")
                .compactMap { line -> WindowsHostCandidate? in
                    let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2 else { return nil }
                    let ports = parts[1].split(separator: ",").map(String.init)
                    let name = parts.count >= 3 ? parts[2] : ""
                    return WindowsHostCandidate(ip: parts[0], ports: ports, name: name)
                }
                .sorted { lhs, rhs in
                    if lhs.ports.contains("22") != rhs.ports.contains("22") {
                        return lhs.ports.contains("22")
                    }
                    return lhs.ip.localizedStandardCompare(rhs.ip) == .orderedAscending
                }
        } catch {
            return []
        }
    }

    private func toggleInstallerServer() {
        if installerServerProcess?.isRunning == true {
            stopInstallerServer()
        } else {
            startInstallerServer()
        }
    }

    private func startInstallerServer() {
        guard installerServerProcess?.isRunning != true else { return }
        guard let zip = installerZipURL(), FileManager.default.fileExists(atPath: zip.path) else {
            uiModel.windowsSetupStatus = "Windows installer zip not found in dist"
            uiModel.windowsInstallerURL = ""
            uiModel.windowsInstallCommand = ""
            return
        }
        guard let localIP = preferredLocalIPv4Address() else {
            uiModel.windowsSetupStatus = "No LAN IP found for installer sharing"
            return
        }

        let distURL = zip.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(installerPort)", "--bind", "0.0.0.0"]
        process.currentDirectoryURL = distURL
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.installerServerProcess === process else { return }
                self?.installerServerProcess = nil
                self?.uiModel.isServingInstaller = false
                self?.uiModel.windowsInstallerURL = ""
                self?.uiModel.windowsInstallCommand = ""
            }
        }

        do {
            try process.run()
            installerServerProcess = process
            let url = "http://\(localIP):\(installerPort)/Portal-Windows-installer.zip"
            uiModel.isServingInstaller = true
            uiModel.windowsInstallerURL = url
            uiModel.windowsInstallCommand = windowsPowerShellInstallCommand(url: url)
            uiModel.windowsSetupStatus = "Installer sharing active"
        } catch {
            uiModel.windowsSetupStatus = "Installer sharing failed: \(error.localizedDescription)"
        }
    }

    private func stopInstallerServer() {
        if installerServerProcess?.isRunning == true {
            installerServerProcess?.terminate()
        }
        installerServerProcess = nil
        uiModel.isServingInstaller = false
        uiModel.windowsInstallerURL = ""
        uiModel.windowsInstallCommand = ""
        if uiModel.windowsSetupStatus == "Installer sharing active" {
            uiModel.windowsSetupStatus = "Installer sharing stopped"
        }
    }

    private func copyWindowsInstallCommand() {
        guard !uiModel.windowsInstallCommand.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(uiModel.windowsInstallCommand, forType: .string)
        uiModel.windowsSetupStatus = "Windows install command copied"
    }

    private func installerZipURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent().appendingPathComponent("Portal-Windows-installer.zip")
        }

        let cwdZip = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/Portal-Windows-installer.zip")
        if FileManager.default.fileExists(atPath: cwdZip.path) {
            return cwdZip
        }
        return nil
    }

    private func windowsPowerShellInstallCommand(url: String) -> String {
        """
        $zip="$env:TEMP\\Portal-Windows-installer.zip"; $dir="$env:TEMP\\Portal-Windows-installer"; Invoke-WebRequest "\(url)" -OutFile $zip; Unblock-File $zip; Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue; Expand-Archive -Force $zip $dir; Get-ChildItem $dir -Recurse | Unblock-File; Set-Location $dir; powershell -NoProfile -ExecutionPolicy Bypass -File .\\install-portal.ps1 -Launch
        """
    }

    private func preferredLocalIPv4Address() -> String? {
        let addresses = localIPv4Addresses()
        return addresses.first { $0.hasPrefix("192.168.") }
            ?? addresses.first { $0.hasPrefix("10.") }
            ?? addresses.first { $0.hasPrefix("172.") }
            ?? addresses.first
    }

    private func subnetPrefix(for ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.dropLast().joined(separator: ".")
    }

    private func refreshIpLabel() {
        let ips = localIPv4Addresses()
        ipLabel.stringValue = ips.isEmpty ? "IP: not found" : "IP: \(ips.joined(separator: ", "))"
        uiModel.ip = ips.isEmpty ? "not found" : ips.joined(separator: ", ")
    }

    private func refreshDisplayLabel() {
        let displays = displayInfos()
        arrangementView.macDisplays = displays
        arrangementView.windowsDisplays = remoteWindowsDisplays
        arrangementView.machineOffsets = machineOffsets
        guard !displays.isEmpty else {
            arrangementLabel.stringValue = "Arrangement: not found"
            uiModel.arrangement = "not found"
            return
        }
        server.sendLocalDisplayLayout()
        let macSummary = displaySummary(displays)
        let windowsSummary = remoteWindowsDisplays.isEmpty ? "waiting" : displaySummary(remoteWindowsDisplays)
        arrangementLabel.stringValue = "Mac: \(macSummary)\nWindows: \(windowsSummary)"
        uiModel.arrangement = "Mac: \(macSummary)\nWindows: \(windowsSummary)"
    }

    private func activationForWindows(at point: CGPoint) -> EdgeActivation? {
        guard bidirectionalWindowsControlEnabled else { return nil }
        guard running, server.canControlWindows else { return nil }
        guard let display = displayInfos().first(where: { $0.frame.contains(point) }) else { return nil }
        let threshold: CGFloat = 1.5
        let edge = uiModel.edge
        let isAtEdge = switch edge {
        case .left:
            point.x <= display.frame.minX + threshold
        case .right:
            point.x >= display.frame.maxX - 1 - threshold
        case .top:
            point.y >= display.frame.maxY - 1 - threshold
        case .bottom:
            point.y <= display.frame.minY + threshold
        }
        guard isAtEdge else { return nil }
        let xRatio = display.frame.width <= 1 ? 0.5 : Double((point.x - display.frame.minX) / display.frame.width)
        let yRatio = display.frame.height <= 1 ? 0.5 : Double((point.y - display.frame.minY) / display.frame.height)
        return EdgeActivation(
            edge: edge,
            xRatio: max(0, min(1, xRatio)),
            yRatio: max(0, min(1, yRatio)),
            display: display
        )
    }

    private func displaySummary(_ displays: [DisplayInfo]) -> String {
        let items = displays.enumerated().map { index, display in
            let frame = display.frame
            return "\(index + 1)\(display.isPrimary ? "*" : ""): \(Int(frame.width))x\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))"
        }
        return "\(displays.count) - \(items.joined(separator: " | "))"
    }

    private func resolveActivationTarget(edge: Edge, xRatio _: Double, yRatio _: Double, sourceDisplay: DisplayInfo?) -> CGRect? {
        let items = arrangementView.arrangementItems()
        let windowsItems = items.filter { $0.machine == "windows" }
        let macItems = items.filter { $0.machine == "mac" }
        guard !macItems.isEmpty else { return nil }

        func fallbackTarget() -> CGRect? {
            macItems.first(where: \.isPrimary)?.nativeFrame ?? macItems.first?.nativeFrame
        }

        let sourceItem: ArrangementItem?
        if let sourceDisplay {
            sourceItem = windowsItems.first { displayMatches(item: $0, display: sourceDisplay) }
        } else {
            sourceItem = windowsItems.first(where: \.isPrimary) ?? (windowsItems.count == 1 ? windowsItems[0] : nil)
        }
        guard let sourceItem else { return fallbackTarget() }

        let candidates = macItems.filter { edgeCandidate($0.virtualFrame, isOn: edge, from: sourceItem.virtualFrame) }
        guard !candidates.isEmpty else { return fallbackTarget() }
        return candidates.min { lhs, rhs in
            edgeScore(edge: edge, source: sourceItem.virtualFrame, target: lhs.virtualFrame) <
                edgeScore(edge: edge, source: sourceItem.virtualFrame, target: rhs.virtualFrame)
        }?.nativeFrame
    }

    private func arrangementAllowsReturn(edge: Edge, point: CGPoint) -> Bool {
        let items = arrangementView.arrangementItems()
        let windowsItems = items.filter { $0.machine == "windows" }
        if windowsItems.isEmpty || machineOffsets.isEmpty {
            return true
        }
        guard let sourceItem = items.first(where: {
            $0.machine == "mac" && $0.nativeFrame.contains(point)
        }) else { return false }
        if windowsItems.contains(where: { edgeCandidate($0.virtualFrame, isOn: edge, from: sourceItem.virtualFrame) }) {
            return true
        }
        let hasAnyAdjacent = windowsItems.contains { window in
            Edge.allCases.contains { candidateEdge in
                edgeCandidate(window.virtualFrame, isOn: candidateEdge, from: sourceItem.virtualFrame)
            }
        }
        if !hasAnyAdjacent {
            return true
        }
        return windowsItems.contains {
            edgeCandidate($0.virtualFrame, isOn: edge, from: sourceItem.virtualFrame)
        }
    }

    private func displayMatches(item: ArrangementItem, display: DisplayInfo) -> Bool {
        item.name == display.name &&
            abs(item.nativeFrame.minX - display.frame.minX) < 1 &&
            abs(item.nativeFrame.minY - display.frame.minY) < 1 &&
            abs(item.nativeFrame.width - display.frame.width) < 1 &&
            abs(item.nativeFrame.height - display.frame.height) < 1
    }

    private func edgeScore(edge: Edge, source: CGRect, target: CGRect) -> CGFloat {
        let sidePenalty: CGFloat
        let edgeDistance: CGFloat
        let axisPenalty: CGFloat
        switch edge {
        case .left:
            sidePenalty = target.midX <= source.midX ? 0 : 1_000_000
            edgeDistance = abs(source.minX - target.maxX)
            axisPenalty = overlapPenalty(source.minY, source.maxY, target.minY, target.maxY)
        case .right:
            sidePenalty = target.midX >= source.midX ? 0 : 1_000_000
            edgeDistance = abs(target.minX - source.maxX)
            axisPenalty = overlapPenalty(source.minY, source.maxY, target.minY, target.maxY)
        case .top:
            sidePenalty = target.midY >= source.midY ? 0 : 1_000_000
            edgeDistance = abs(target.minY - source.maxY)
            axisPenalty = overlapPenalty(source.minX, source.maxX, target.minX, target.maxX)
        case .bottom:
            sidePenalty = target.midY <= source.midY ? 0 : 1_000_000
            edgeDistance = abs(source.minY - target.maxY)
            axisPenalty = overlapPenalty(source.minX, source.maxX, target.minX, target.maxX)
        }
        return sidePenalty + edgeDistance * 2 + axisPenalty
    }

    private func edgeCandidate(_ target: CGRect, isOn edge: Edge, from source: CGRect) -> Bool {
        switch edge {
        case .left:
            return abs(source.minX - target.maxX) <= 24 &&
                rangesOverlap(source.minY, source.maxY, target.minY, target.maxY)
        case .right:
            return abs(target.minX - source.maxX) <= 24 &&
                rangesOverlap(source.minY, source.maxY, target.minY, target.maxY)
        case .top:
            return abs(target.minY - source.maxY) <= 24 &&
                rangesOverlap(source.minX, source.maxX, target.minX, target.maxX)
        case .bottom:
            return abs(source.minY - target.maxY) <= 24 &&
                rangesOverlap(source.minX, source.maxX, target.minX, target.maxX)
        }
    }

    private func rangesOverlap(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> Bool {
        min(aMax, bMax) - max(aMin, bMin) > 1
    }

    private func overlapPenalty(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> CGFloat {
        let overlap = min(aMax, bMax) - max(aMin, bMin)
        if overlap > 1 {
            let aMid = (aMin + aMax) / 2
            let bMid = (bMin + bMax) / 2
            return abs(aMid - bMid) * 0.05
        }
        let gap = max(aMin, bMin) - min(aMax, bMax)
        return 100_000 + max(0, gap) * 3
    }

    private func loadMachineOffsets() -> [String: CGPoint] {
        guard let data = UserDefaults.standard.data(forKey: "portal.arrangement.origins.v1"),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]]
        else { return [:] }
        var offsets: [String: CGPoint] = [:]
        for (key, point) in raw {
            guard key == "mac" || key == "windows" else { continue }
            if let x = point["x"], let y = point["y"] {
                offsets[key] = CGPoint(x: x, y: y)
            }
        }
        return offsets
    }

    private func saveMachineOffsets(_ offsets: [String: CGPoint]) {
        let raw = offsets.mapValues { ["x": Double($0.x), "y": Double($0.y)] }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        UserDefaults.standard.set(data, forKey: "portal.arrangement.origins.v1")
    }

    private func displayInfos() -> [DisplayInfo] {
        let screenNames = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let name = screen.localizedName.isEmpty ? "Mac Display \(number.uint32Value)" : screen.localizedName
            return (number.uint32Value, name)
        })

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).enumerated().map { index, id in
            let name = screenNames[id] ?? "Mac Display \(index + 1)"
            return DisplayInfo(name: name, frame: CGDisplayBounds(id), isPrimary: CGDisplayIsMain(id) != 0)
        }
    }

    private func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard item.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                item.pointee.ifa_addr,
                socklen_t(item.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                addresses.append(String(cString: hostname))
            }
        }
        return addresses
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
