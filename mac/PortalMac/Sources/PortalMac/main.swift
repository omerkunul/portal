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
    var activationReturnEdgeProvider: ((Edge, DisplayInfo?) -> Edge?)?
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
                var linkedReturnEdge: Edge?
                var shouldActivate = true
                if let activationTargetProvider {
                    if Thread.isMainThread {
                        targetFrame = activationTargetProvider(edge, xRatio, yRatio, sourceDisplay)
                        linkedReturnEdge = activationReturnEdgeProvider?(edge, sourceDisplay)
                    } else {
                        DispatchQueue.main.sync {
                            targetFrame = activationTargetProvider(edge, xRatio, yRatio, sourceDisplay)
                            linkedReturnEdge = activationReturnEdgeProvider?(edge, sourceDisplay)
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
                    let returnEdge = linkedReturnEdge ?? edge.opposite
                    self.injector.returnEdge = returnEdge
                    self.recordEvent("return edge \(returnEdge.rawValue)")
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

final class InstallerHTTPServer {
    private let queue = DispatchQueue(label: "portal.installer.http")
    private var listener: NWListener?
    private var fileURL: URL?
    private let servedPath = "/Portal-Windows-installer.zip"
    var onFailure: ((String) -> Void)?

    func start(fileURL: URL, port: UInt16) throws {
        stop()
        self.fileURL = fileURL

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.stop()
                DispatchQueue.main.async {
                    self.onFailure?(Self.message(for: error))
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        fileURL = nil
    }

    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EADDRINUSE) {
            return "Installer sharing failed: port is already in use"
        }
        return "Installer sharing failed: \(nsError.localizedDescription)"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                DispatchQueue.main.async {
                    self.onFailure?(Self.message(for: error))
                }
                return
            }

            var requestBuffer = buffer
            if let data {
                requestBuffer.append(data)
            }

            if requestBuffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: connection, request: requestBuffer)
                return
            }

            if isComplete || requestBuffer.count >= 8192 {
                self.sendSimpleResponse(on: connection, status: "400 Bad Request", body: Data())
                return
            }

            self.receiveRequest(on: connection, buffer: requestBuffer)
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        guard
            let header = String(data: request, encoding: .utf8),
            let firstLine = header.components(separatedBy: "\r\n").first
        else {
            sendSimpleResponse(on: connection, status: "400 Bad Request", body: Data())
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendSimpleResponse(on: connection, status: "400 Bad Request", body: Data())
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])
        guard method == "GET", path == servedPath, let fileURL else {
            sendSimpleResponse(on: connection, status: "404 Not Found", body: Data())
            return
        }

        do {
            let body = try Data(contentsOf: fileURL)
            sendFileResponse(on: connection, body: body)
        } catch {
            sendSimpleResponse(on: connection, status: "500 Internal Server Error", body: Data())
            DispatchQueue.main.async {
                self.onFailure?("Installer file could not be read")
            }
        }
    }

    private func sendFileResponse(on connection: NWConnection, body: Data) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/zip\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Content-Disposition: attachment; filename=\"Portal-Windows-installer.zip\"\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendSimpleResponse(on connection: NWConnection, status: String, body: Data) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
    private let statusLabel = NSTextField(labelWithString: "Stopped")
    private let ipLabel = NSTextField(labelWithString: "IP: checking...")
    private let displayLabel = NSTextField(labelWithString: "Displays: checking...")
    private let permissionLabel = NSTextField(labelWithString: "Accessibility: use the enabled switch in System Settings")
    private let awdlLabel = NSTextField(labelWithString: "Low latency: checking...")
    private let clipboardLabel = NSTextField(labelWithString: "Clipboard: starting...")
    private let eventLabel = NSTextField(labelWithString: "Stats: idle")
    private let motionGraph = MotionGraphView()
    private let uiModel = PortalUIModel()
    private let arrangementView = DisplayArrangementView()
    private var running = false
    private var eventCount = 0
    private var starting = false
    private var autoStarted = false
    private var remoteWindowsDisplays: [DisplayInfo] = []
    private var machineOffsets: [String: CGPoint] = [:]
    private var anchorLink: ArrangementAnchorLink?
    private var accessibilityTimer: Timer?
    private var networkTimer: Timer?
    private let installerServer = InstallerHTTPServer()
    private var installerServerStopRequested = false
    private let installerPort: UInt16 = 8123
    private var activeInstallerPort: UInt16?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        realtimeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInteractive, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Portal realtime mouse and keyboard sharing"
        )
        server.motionProbe = motionProbe
        motionLogWriter = MotionLogWriter(probe: motionProbe)
        machineOffsets = loadMachineOffsets()
        anchorLink = loadAnchorLink()
        arrangementView.machineOffsets = machineOffsets
        arrangementView.anchorLink = anchorLink
        arrangementView.onAnchorLinkChanged = { [weak self] link in
            self?.anchorLink = link
            self?.saveAnchorLink(link)
            self?.server.sendLocalDisplayLayout()
            self?.refreshDisplayLabel()
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
        server.activationReturnEdgeProvider = { [weak self] _, sourceDisplay in
            self?.resolveActivationReturnEdge(sourceDisplay: sourceDisplay)
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
        installerServer.onFailure = { [weak self] message in
            self?.installerServerStopRequested = false
            self?.uiModel.isServingInstaller = false
            self?.uiModel.windowsInstallerURL = ""
            self?.uiModel.windowsInstallCommand = ""
            self?.uiModel.windowsSetupStatus = message
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
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PortalChromeMetrics.windowWidth,
                height: PortalChromeMetrics.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Portal"
        window.isReleasedWhenClosed = false
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.isEnabled = false
        }
        let fixedSize = NSSize(
            width: PortalChromeMetrics.windowWidth,
            height: PortalChromeMetrics.windowHeight
        )
        window.setContentSize(fixedSize)
        window.minSize = fixedSize
        window.maxSize = fixedSize
        enforceFixedWindowFrame()
        motionGraph.probe = motionProbe
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
        enforceFixedWindowFrame()
        refreshIpLabel()
        refreshDisplayLabel()
    }

    private func enforceFixedWindowFrame() {
        let primaryScreen = NSScreen.screens.max {
            ($0.visibleFrame.width * $0.visibleFrame.height) < ($1.visibleFrame.width * $1.visibleFrame.height)
        } ?? NSScreen.main
        guard let screen = primaryScreen else {
            let contentRect = NSRect(
                x: 0,
                y: 0,
                width: PortalChromeMetrics.windowWidth,
                height: PortalChromeMetrics.windowHeight
            )
            let frameRect = window.frameRect(forContentRect: contentRect)
            window.setFrame(frameRect, display: true)
            window.center()
            return
        }

        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: PortalChromeMetrics.windowWidth,
            height: PortalChromeMetrics.windowHeight
        )
        let frameRect = window.frameRect(forContentRect: contentRect)
        let visible = screen.visibleFrame
        let target = NSRect(
            x: visible.midX - frameRect.width / 2,
            y: visible.midY - frameRect.height / 2,
            width: frameRect.width,
            height: frameRect.height
        )
        window.setFrame(target, display: true)
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
        let edge = anchorLink?.macEdge ?? .right
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
        enforceFixedWindowFrame()
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
        anchorLink = nil
        saveAnchorLink(nil)
        arrangementView.machineOffsets = machineOffsets
        arrangementView.anchorLink = nil
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
            uiModel.awdlEnabled = true
            uiModel.awdlText = awdlLabel.stringValue
            uiModel.awdlColor = .portalOrange
        case false:
            awdlLabel.stringValue = "Disabled - low latency mode"
            awdlLabel.textColor = .systemGreen
            uiModel.awdlEnabled = false
            uiModel.awdlText = awdlLabel.stringValue
            uiModel.awdlColor = .portalGreen
        case nil:
            awdlLabel.stringValue = "Low latency: AWDL interface not found"
            awdlLabel.textColor = .secondaryLabelColor
            uiModel.awdlEnabled = false
            uiModel.awdlText = awdlLabel.stringValue
            uiModel.awdlColor = .secondary
        }
    }

    private func setAwdl(enabled: Bool, promptIfNeeded: Bool, completion: ((Bool) -> Void)? = nil) {
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
        if uiModel.isServingInstaller {
            stopInstallerServer()
        } else {
            startInstallerServer()
        }
    }

    private func startInstallerServer() {
        guard !uiModel.isServingInstaller else { return }
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

        installerServerStopRequested = false
        uiModel.windowsSetupStatus = "Starting installer sharing..."
        uiModel.isServingInstaller = false
        uiModel.windowsInstallerURL = ""
        uiModel.windowsInstallCommand = ""

        guard let selectedPort = firstAvailableInstallerPort() else {
            activeInstallerPort = nil
            uiModel.windowsSetupStatus = "Installer sharing failed: no free local port found"
            return
        }

        do {
            try installerServer.start(fileURL: zip, port: selectedPort)
            activeInstallerPort = selectedPort
            let url = "http://\(localIP):\(selectedPort)/Portal-Windows-installer.zip"
            uiModel.isServingInstaller = true
            uiModel.windowsInstallerURL = url
            uiModel.windowsInstallCommand = windowsPowerShellInstallCommand(url: url)
            uiModel.windowsSetupStatus = "Installer sharing active"
        } catch {
            activeInstallerPort = nil
            uiModel.windowsSetupStatus = InstallerHTTPServer.message(for: error)
        }
    }

    private func stopInstallerServer() {
        installerServerStopRequested = true
        installerServer.stop()
        activeInstallerPort = nil
        uiModel.isServingInstaller = false
        uiModel.windowsInstallerURL = ""
        uiModel.windowsInstallCommand = ""
        if uiModel.windowsSetupStatus == "Installer sharing active" || uiModel.windowsSetupStatus == "Starting installer sharing..." {
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

    private func firstAvailableInstallerPort() -> UInt16? {
        let candidatePorts = [installerPort] + Array((installerPort + 1)...(installerPort + 10))
        return candidatePorts.first(where: isLocalTCPPortAvailable)
    }

    private func isLocalTCPPortAvailable(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("0.0.0.0"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
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
        arrangementView.anchorLink = anchorLink
        guard !displays.isEmpty else {
            uiModel.arrangement = "not found"
            return
        }
        server.sendLocalDisplayLayout()
        let macSummary = displaySummary(displays)
        let windowsSummary = remoteWindowsDisplays.isEmpty ? "waiting" : displaySummary(remoteWindowsDisplays)
        let linkSummary = arrangementLinkSummary()
        uiModel.arrangement = "Mac: \(macSummary)\nWindows: \(windowsSummary)\nLink: \(linkSummary)"
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
        if let linked = linkedMacItem(forWindowsItem: sourceItem, in: items) {
            return linked.nativeFrame
        }

        let candidates = macItems.filter { edgeCandidate($0.virtualFrame, isOn: edge, from: sourceItem.virtualFrame) }
        guard !candidates.isEmpty else { return fallbackTarget() }
        return candidates.min { lhs, rhs in
            edgeScore(edge: edge, source: sourceItem.virtualFrame, target: lhs.virtualFrame) <
                edgeScore(edge: edge, source: sourceItem.virtualFrame, target: rhs.virtualFrame)
        }?.nativeFrame
    }

    private func resolveActivationReturnEdge(sourceDisplay: DisplayInfo?) -> Edge? {
        guard let sourceDisplay, let anchorLink else { return nil }
        let items = arrangementView.arrangementItems()
        let windowsItems = items.filter { $0.machine == "windows" }
        guard let sourceItem = windowsItems.first(where: { displayMatches(item: $0, display: sourceDisplay) }),
              sourceItem.id == anchorLink.windowsItemId
        else { return nil }
        return anchorLink.macEdge
    }

    private func arrangementAllowsReturn(edge: Edge, point: CGPoint) -> Bool {
        let items = arrangementView.arrangementItems()
        let windowsItems = items.filter { $0.machine == "windows" }
        if windowsItems.isEmpty || anchorLink == nil {
            return true
        }
        guard let sourceItem = items.first(where: {
            $0.machine == "mac" && $0.nativeFrame.contains(point)
        }) else { return false }
        if let anchorLink, sourceItem.id == anchorLink.macItemId {
            return edge == anchorLink.macEdge
        }
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

    private func linkedMacItem(forWindowsItem windowsItem: ArrangementItem, in items: [ArrangementItem]) -> ArrangementItem? {
        guard let anchorLink, windowsItem.id == anchorLink.windowsItemId else { return nil }
        return items.first { $0.machine == "mac" && $0.id == anchorLink.macItemId }
    }

    private func arrangementLinkSummary() -> String {
        guard let anchorLink else { return "select a Mac point and a Windows point" }
        let items = arrangementView.arrangementItems()
        let mac = items.first { $0.id == anchorLink.macItemId }
        let windows = items.first { $0.id == anchorLink.windowsItemId }
        let macName = mac.map { "M\($0.index + 1)\($0.isPrimary ? "*" : "")" } ?? "Mac"
        let windowsName = windows.map { "W\($0.index + 1)\($0.isPrimary ? "*" : "")" } ?? "Windows"
        return "\(macName) \(anchorLink.macEdge.rawValue) <-> \(windowsName) \(anchorLink.windowsEdge.rawValue)"
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

    private func loadAnchorLink() -> ArrangementAnchorLink? {
        guard let data = UserDefaults.standard.data(forKey: "portal.arrangement.anchorLink.v1") else {
            return nil
        }
        return try? JSONDecoder().decode(ArrangementAnchorLink.self, from: data)
    }

    private func saveAnchorLink(_ link: ArrangementAnchorLink?) {
        guard let link else {
            UserDefaults.standard.removeObject(forKey: "portal.arrangement.anchorLink.v1")
            return
        }
        guard let data = try? JSONEncoder().encode(link) else { return }
        UserDefaults.standard.set(data, forKey: "portal.arrangement.anchorLink.v1")
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
