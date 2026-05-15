import AppKit
import ApplicationServices
import Network
import Darwin
import SwiftUI

enum PortalLog {
    private static let url = URL(fileURLWithPath: "/tmp/portal-debug.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

enum Edge: String, CaseIterable {
    case left
    case right
    case top
    case bottom
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

final class InputInjector {
    enum MoveMode {
        case event
        case warp
    }

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let keyCodes: [String: CGKeyCode] = [
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
        let epsilon: CGFloat = 0.5
        let desktop = desktopBounds()
        let candidates: [CGRect]
        switch edge {
        case .left:
            candidates = frames.filter { abs($0.maxX - desktop.maxX) <= epsilon }
        case .right:
            candidates = frames.filter { abs($0.minX - desktop.minX) <= epsilon }
        case .top:
            candidates = frames.filter { abs($0.maxY - desktop.maxY) <= epsilon }
        case .bottom:
            candidates = frames.filter { abs($0.minY - desktop.minY) <= epsilon }
        }
        let edgeFrames = candidates.isEmpty ? frames : candidates

        switch edge {
        case .left, .right:
            let minY = edgeFrames.map(\.minY).min() ?? desktop.minY
            let maxY = edgeFrames.map(\.maxY).max() ?? desktop.maxY
            let desiredY = minY + (maxY - minY) * CGFloat(max(0, min(1, yRatio)))
            let frame = edgeFrames.first { desiredY >= $0.minY && desiredY < $0.maxY }
                ?? edgeFrames.min { abs($0.midY - desiredY) < abs($1.midY - desiredY) }
                ?? desktop
            let x = edge == .left ? frame.maxX - inset : frame.minX + inset
            let y = max(frame.minY, min(frame.maxY - 1, desiredY))
            return CGPoint(x: x, y: y)
        case .top, .bottom:
            let minX = edgeFrames.map(\.minX).min() ?? desktop.minX
            let maxX = edgeFrames.map(\.maxX).max() ?? desktop.maxX
            let desiredX = minX + (maxX - minX) * CGFloat(max(0, min(1, xRatio)))
            let frame = edgeFrames.first { desiredX >= $0.minX && desiredX < $0.maxX }
                ?? edgeFrames.min { abs($0.midX - desiredX) < abs($1.midX - desiredX) }
                ?? desktop
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
        guard let frame = displayFrame(containing: point) ?? nearestDisplayFrame(to: point) else { return }
        let threshold: CGFloat = 1.5
        let shouldRelease = switch returnEdge {
        case .left:
            point.x <= frame.minX + threshold && displayFrame(containing: CGPoint(x: frame.minX - 2, y: point.y)) == nil
        case .right:
            point.x >= frame.maxX - 1 - threshold && displayFrame(containing: CGPoint(x: frame.maxX + 1, y: point.y)) == nil
        case .top:
            point.y <= frame.minY + threshold && displayFrame(containing: CGPoint(x: point.x, y: frame.minY - 2)) == nil
        case .bottom:
            point.y >= frame.maxY - 1 - threshold && displayFrame(containing: CGPoint(x: point.x, y: frame.maxY + 1)) == nil
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
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let plot = bounds.insetBy(dx: 10, dy: 24)
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        for step in 0...3 {
            let y = plot.minY + plot.height * CGFloat(step) / 3.0
            let path = NSBezierPath()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.line(to: CGPoint(x: plot.maxX, y: y))
            path.stroke()
        }

        guard !cachedSamples.isEmpty else {
            drawLabel("Mouse input graph: waiting for packets", in: bounds)
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
                NSColor.systemGreen.withAlphaComponent(0.8).setFill()
            }
            rect.fill()
        }

        let recent = cachedSamples.suffix(30)
        let packets = recent.reduce(0) { $0 + $1.packets }
        let raw = recent.reduce(0) { $0 + $1.raw }
        let receiveGap = recent.map(\.maxReceiveGapMs).max() ?? 0
        let senderGap = recent.map(\.maxSenderGapMs).max() ?? 0
        let lost = recent.reduce(0) { $0 + $1.lostPackets }
        let label = String(format: "Input graph: %d pkt/s, %d raw/s, win %.1f ms, mac %.1f ms, lost %d", packets, raw, senderGap, receiveGap, lost)
        drawLabel(label, in: bounds)
    }

    private func drawLabel(_ text: String, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        text.draw(at: CGPoint(x: rect.minX + 10, y: rect.maxY - 18), withAttributes: attrs)
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
    let motionGraph: MotionGraphView
    let arrangementView: DisplayArrangementView
    let toggleServer: () -> Void
    let toggleAwdl: (Bool) -> Void
    let openAccessibility: () -> Void
    let resetArrangement: () -> Void

    var body: some View {
        TabView {
            controlView
                .tabItem { Text("Control") }
            arrangementTab
                .tabItem { Text("Arrangement") }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }

    private var controlView: some View {
        VStack(spacing: 18) {
            Text("Portal")
                .font(.title3.weight(.semibold))

            settingsGrid {
                SettingsRow("Connection") {
                    Button(model.isRunning ? "Stop" : (model.isStarting ? "Starting..." : "Start"), action: toggleServer)
                        .disabled(model.isStarting)
                        .frame(width: 240)
                }
                SettingsRow("Port") {
                    TextField("", text: $model.port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                SettingsRow("Mac IP") {
                    Text(model.ip)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SettingsRow("Status") {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SettingsRow("Access") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.accessibility)
                            .foregroundStyle(model.accessibilityOK ? .green : .orange)
                        Button("Open Accessibility Settings", action: openAccessibility)
                    }
                }
                SettingsRow("AWDL") {
                    Toggle(isOn: Binding(
                        get: { model.awdlEnabled },
                        set: { toggleAwdl($0) }
                    )) {
                        Text(model.awdlText)
                            .foregroundStyle(model.awdlColor)
                    }
                    .toggleStyle(.switch)
                }
            }

            statsPanel
        }
        .padding(.top, 8)
    }

    private var arrangementTab: some View {
        VStack(spacing: 18) {
            Text("Arrangement")
                .font(.title3.weight(.semibold))

            settingsGrid {
                SettingsRow("Return edge") {
                    Picker("", selection: $model.edge) {
                        ForEach(Edge.allCases, id: \.self) { edge in
                            Text(edge.rawValue).tag(edge)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                SettingsRow("Displays") {
                    Text(model.arrangement)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                }
                SettingsRow("Layout") {
                    Button("Reset Arrangement", action: resetArrangement)
                        .frame(width: 240)
                }
            }

            DisplayArrangementRepresentable(view: arrangementView)
                .frame(width: 540, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 8)
    }

    private var statsPanel: some View {
        VStack(spacing: 4) {
            Text(model.stats)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            MotionGraphRepresentable(view: motionGraph)
                .frame(height: 68)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(width: 540)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func settingsGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
            content()
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 120, alignment: .leading)
            content
                .frame(minWidth: 300, alignment: .leading)
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
        NSSize(width: 560, height: 430)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let items = arrangementItems()
        guard !items.isEmpty else {
            drawText("No displays found", at: CGPoint(x: 16, y: bounds.midY), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            return
        }

        let transform = dragState?.transform ?? makeTransform(for: items)
        lastTransform = transform

        drawGrid(in: transform.visibleRect)
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        NSBezierPath(rect: transform.visibleRect).stroke()
        renderedRects = []

        for item in items {
            let rect = map(item.virtualFrame, transform: transform)
            renderedRects.append((item.id, item.machine, rect))
            let color = item.machine == "mac"
                ? (item.isPrimary ? NSColor.systemBlue : NSColor.systemGreen)
                : (item.isPrimary ? NSColor.systemOrange : NSColor.systemPurple)
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
            drawCentered(label, in: labelRect, font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: .secondaryLabelColor)
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
        let macDefaults = defaultFrames(for: macDisplays, machine: "mac", xOffset: 0)
        let windowsDefaults = defaultFrames(for: windowsDisplays, machine: "windows", xOffset: -(windowsGroupWidth() + 220))
        let defaults = macDefaults + windowsDefaults
        return defaults.map { item in
            let offset = machineOffsets[item.machine] ?? .zero
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

    private func drawGrid(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.12).setStroke()
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
        machineOffsets[dragState.machine] = CGPoint(
            x: dragState.originalOffset.x + delta.x,
            y: dragState.originalOffset.y + delta.y
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragState != nil else { return }
        dragState = nil
        onOffsetsChanged?(machineOffsets)
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
    var localDisplayProvider: (() -> [DisplayInfo])?
    var arrangementOffsetsProvider: (() -> [String: CGPoint])?
    var activationTargetProvider: ((Edge, Double, Double, DisplayInfo?) -> CGRect?)?
    private var activeConnection: NWConnection?
    private var movePackets = 0
    private var rawMoves = 0
    private var buttons = 0
    private var keys = 0
    private var scrolls = 0
    private var statsWindowMoves = 0
    private var statsWindowRaw = 0
    private var lastStatsAt = Date()

    func start(port: UInt16, returnEdge: Edge) throws {
        PortalLog.write("PortalServer.start begin")
        injector.returnEdge = returnEdge
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
        PortalLog.write("tcp listener start requested")

        try startUdpSocket(port: port)
        PortalLog.write("udp socket started")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activeConnection = nil
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
                    }
                    self?.onStatus?("Windows disconnected")
                case .failed(let error):
                    if let self, self.activeConnection === connection {
                        self.activeConnection = nil
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
        PortalLog.write("startUdpSocket begin port=\(port)")
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
            PortalLog.write("udp bind failed errno=\(error)")
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
        case "activate":
            if let edgeName = obj["edge"] as? String,
               let edge = Edge(rawValue: edgeName) {
                recordEvent("activate \(edgeName)")
                let yRatio = obj["yRatio"] as? Double ?? 0.5
                let xRatio = obj["xRatio"] as? Double ?? 0.5
                let sourceDisplay = (obj["screen"] as? [String: Any]).flatMap(Self.parseDisplayInfo)
                var targetFrame: CGRect?
                if let activationTargetProvider {
                    if Thread.isMainThread {
                        targetFrame = activationTargetProvider(edge, xRatio, yRatio, sourceDisplay)
                    } else {
                        DispatchQueue.main.sync {
                            targetFrame = activationTargetProvider(edge, xRatio, yRatio, sourceDisplay)
                        }
                    }
                }
                inputQueue.async { [weak self] in
                    self?.injector.activate(from: edge, yRatio: yRatio, xRatio: xRatio, targetFrame: targetFrame)
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

        guard let snapshot = readLocalClipboard(from: pasteboard) else { return }
        if snapshot.signature == lastLocalSignature || snapshot.signature == lastAppliedSignature { return }

        if snapshot.byteCount > maxImageBytes {
            lastLocalSignature = snapshot.signature
            publishStatus?("Clipboard: image too large")
            return
        }

        if sendPayload?(snapshot.payload) == true {
            lastLocalSignature = snapshot.signature
            publishStatus?(snapshot.contentType == "text/plain" ? "Clipboard: sent text" : "Clipboard: sent image")
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
    private let server = PortalServer()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        PortalLog.write("app did finish launching")
        NSApp.setActivationPolicy(.regular)
        realtimeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInteractive, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Portal realtime mouse and keyboard sharing"
        )
        PortalLog.write("activity started")
        server.motionProbe = motionProbe
        motionLogWriter = MotionLogWriter(probe: motionProbe)
        PortalLog.write("motion log writer created")
        machineOffsets = loadMachineOffsets()
        PortalLog.write("machine offsets loaded")
        arrangementView.machineOffsets = machineOffsets
        arrangementView.onOffsetsChanged = { [weak self] offsets in
            self?.machineOffsets = offsets
            self?.saveMachineOffsets(offsets)
            self?.server.sendLocalDisplayLayout()
        }
        PortalLog.write("building window")
        buildWindow()
        PortalLog.write("window built")
        showPortalWindow()
        PortalLog.write("window shown")
        buildStatusItem()
        PortalLog.write("status item built")
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
        clipboardBridge.start(
            send: { [weak self] payload in self?.server.sendClipboard(payload) ?? false },
            status: { [weak self] status in self?.clipboardLabel.stringValue = status }
        )
        PortalLog.write("clipboard bridge started")
        eventLabel.stringValue = "Stats: idle"
        DispatchQueue.main.async { [weak self] in
            PortalLog.write("auto start dispatch fired")
            self?.autoStartOnce()
        }
        PortalLog.write("auto start scheduled")
        refreshAccessibilityStatus()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityStatus()
        }
        refreshNetworkStatus()
        refreshDisplayLabel()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            if self?.running == true && self?.awdlSwitch.state == .off {
                _ = self?.setAwdlSync(enabled: false)
            }
            self?.refreshNetworkStatus()
            self?.refreshDisplayLabel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkTimer?.invalidate()
        accessibilityTimer?.invalidate()
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Portal"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 460)
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
            resetArrangement: { [weak self] in self?.resetArrangement() }
        )
        window.contentView = NSHostingView(rootView: rootView)
        refreshIpLabel()
        refreshDisplayLabel()
    }

    private func positionWindowOnMainScreen() {
        let primaryScreen = NSScreen.screens.first { screen in
            screen.frame.origin.x == 0 && screen.frame.origin.y == 0
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
        PortalLog.write("toggleServer starting=\(starting) running=\(running)")
        if starting { return }
        if running {
            server.stop()
            running = false
            updateRunningControls()
            setStatus("Stopped")
            setAwdl(enabled: true, promptIfNeeded: false)
            return
        }

        guard let port = UInt16(portField.stringValue) else {
            statusLabel.stringValue = "Invalid port"
            return
        }
        refreshAccessibilityStatus()
        let edge = Edge(rawValue: edgePopup.titleOfSelectedItem ?? "left") ?? .left
        starting = true
        startButton.isEnabled = false
        statusStartStopItem?.isEnabled = false
        setStatus("Preparing low latency...")
        ensureAwdlSudoersReady { [weak self] ready in
            guard let self else { return }
            PortalLog.write("awdl sudoers ready=\(ready)")
            if !ready {
                self.starting = false
                self.startButton.isEnabled = true
                self.statusStartStopItem?.isEnabled = true
                self.setStatus("Start cancelled: AWDL permission not installed")
                self.refreshNetworkStatus()
                return
            }

            let awdlDisabled = self.setAwdlSync(enabled: false)
            PortalLog.write("set awdl down sync result=\(awdlDisabled)")
            self.refreshNetworkStatus()
            self.startServer(port: port, edge: edge)
        }
    }

    private func startServer(port: UInt16, edge: Edge) {
        PortalLog.write("startServer port=\(port) edge=\(edge.rawValue)")
        do {
            try server.start(port: port, returnEdge: edge)
            PortalLog.write("server.start returned")
            running = true
            updateRunningControls()
        } catch {
            PortalLog.write("server.start failed \(error.localizedDescription)")
            setStatus("Start failed: \(error.localizedDescription)")
            _ = setAwdlSync(enabled: true)
            refreshNetworkStatus()
        }
        starting = false
        startButton.isEnabled = true
        statusStartStopItem?.isEnabled = true
    }

    @objc private func showPortalWindow() {
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
        updateStatusMenu()
    }

    private func updateRunningControls() {
        startButton.title = running ? "Stop" : "Start"
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
        setAwdl(enabled: awdlSwitch.state == .on, promptIfNeeded: true)
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
        refreshDisplayLabel()
    }

    private func recordEvent(_ event: String) {
        eventCount += 1
        eventLabel.stringValue = "Events \(eventCount) · \(event)"
    }

    private func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        permissionLabel.stringValue = trusted ? "Accessibility: granted" : "Accessibility: not trusted - click/keyboard will not work"
        permissionLabel.textColor = trusted ? .systemGreen : .systemOrange
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
        case false:
            awdlLabel.stringValue = "Disabled - low latency mode"
            awdlLabel.textColor = .systemGreen
            awdlSwitch.state = .off
            awdlSwitch.isEnabled = true
        case nil:
            awdlLabel.stringValue = "Low latency: AWDL interface not found"
            awdlLabel.textColor = .secondaryLabelColor
            awdlSwitch.state = .off
            awdlSwitch.isEnabled = false
        }
    }

    private func setAwdl(enabled: Bool, promptIfNeeded: Bool, completion: ((Bool) -> Void)? = nil) {
        awdlSwitch.isEnabled = false
        awdlLabel.stringValue = enabled ? "Enabling AWDL..." : "Disabling AWDL..."
        awdlLabel.textColor = .secondaryLabelColor

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

    private func refreshIpLabel() {
        let ips = localIPv4Addresses()
        ipLabel.stringValue = ips.isEmpty ? "IP: not found" : "IP: \(ips.joined(separator: ", "))"
    }

    private func refreshDisplayLabel() {
        let displays = displayInfos()
        arrangementView.macDisplays = displays
        arrangementView.windowsDisplays = remoteWindowsDisplays
        arrangementView.machineOffsets = machineOffsets
        guard !displays.isEmpty else {
            arrangementLabel.stringValue = "Arrangement: not found"
            return
        }
        server.sendLocalDisplayLayout()
        let macSummary = displaySummary(displays)
        let windowsSummary = remoteWindowsDisplays.isEmpty ? "waiting" : displaySummary(remoteWindowsDisplays)
        arrangementLabel.stringValue = "Mac: \(macSummary)\nWindows: \(windowsSummary)"
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

        let sourceItem: ArrangementItem?
        if let sourceDisplay {
            sourceItem = windowsItems.first { displayMatches(item: $0, display: sourceDisplay) }
        } else {
            sourceItem = windowsItems.count == 1 ? windowsItems[0] : nil
        }
        guard let sourceItem else { return nil }

        return macItems.min { lhs, rhs in
            edgeScore(edge: edge, source: sourceItem.virtualFrame, target: lhs.virtualFrame) <
                edgeScore(edge: edge, source: sourceItem.virtualFrame, target: rhs.virtualFrame)
        }?.nativeFrame
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
