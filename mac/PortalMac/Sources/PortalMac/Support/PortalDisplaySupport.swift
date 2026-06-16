import AppKit

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

        guard !cachedSamples.isEmpty else { return }

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

struct ArrangementAnchorLink: Codable, Equatable {
    let macItemId: String
    let macEdge: Edge
    let windowsItemId: String
    let windowsEdge: Edge

    private enum CodingKeys: String, CodingKey {
        case macItemId
        case macEdge
        case windowsItemId
        case windowsEdge
    }

    init(macItemId: String, macEdge: Edge, windowsItemId: String, windowsEdge: Edge) {
        self.macItemId = macItemId
        self.macEdge = macEdge
        self.windowsItemId = windowsItemId
        self.windowsEdge = windowsEdge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macItemId = try container.decode(String.self, forKey: .macItemId)
        windowsItemId = try container.decode(String.self, forKey: .windowsItemId)
        let macEdgeRaw = try container.decode(String.self, forKey: .macEdge)
        let windowsEdgeRaw = try container.decode(String.self, forKey: .windowsEdge)
        macEdge = Edge(rawValue: macEdgeRaw) ?? .right
        windowsEdge = Edge(rawValue: windowsEdgeRaw) ?? .left
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(macItemId, forKey: .macItemId)
        try container.encode(macEdge.rawValue, forKey: .macEdge)
        try container.encode(windowsItemId, forKey: .windowsItemId)
        try container.encode(windowsEdge.rawValue, forKey: .windowsEdge)
    }
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

    private struct AnchorHit {
        let item: ArrangementItem
        let edge: Edge
        let point: CGPoint
    }

    var macDisplays: [DisplayInfo] = [] { didSet { needsDisplay = true } }
    var windowsDisplays: [DisplayInfo] = [] { didSet { needsDisplay = true } }
    var machineOffsets: [String: CGPoint] = [:] { didSet { needsDisplay = true } }
    var anchorLink: ArrangementAnchorLink? { didSet { needsDisplay = true } }
    var onAnchorLinkChanged: ((ArrangementAnchorLink?) -> Void)?

    private var renderedRects: [(id: String, machine: String, rect: NSRect)] = []
    private var renderedAnchors: [AnchorHit] = []
    private var pendingAnchor: AnchorHit?
    private var lastTransform: ViewTransform?
    private var pinnedTransform: ViewTransform?

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
        NSSize(width: NSView.noIntrinsicMetric, height: 240)
    }

    func resetViewport() {
        pinnedTransform = nil
        pendingAnchor = nil
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

        let transform = pinnedTransform ?? makeTransform(for: items)
        lastTransform = transform
        pinnedTransform = transform

        drawGrid(in: transform.visibleRect)
        NSColor(hex: 0x414755, alpha: 0.45).setStroke()
        NSBezierPath(rect: transform.visibleRect).stroke()
        renderedRects = []
        renderedAnchors = []

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
            drawAnchors(for: item, in: rect)
        }

        drawAnchorLink()
        if let pendingAnchor {
            drawPendingAnchor(pendingAnchor)
        }
    }

    private func makeTransform(for items: [ArrangementItem]) -> ViewTransform {
        let union = items.dropFirst().reduce(items[0].virtualFrame) { $0.union($1.virtualFrame) }
        let drawing = bounds.insetBy(dx: 18, dy: 18)
        let scale = max(0.0001, min(drawing.width / max(1, union.width), drawing.height / max(1, union.height)))
        let drawnWidth = union.width * scale
        let drawnHeight = union.height * scale
        let origin = CGPoint(x: drawing.midX - drawnWidth / 2, y: drawing.midY - drawnHeight / 2)
        return ViewTransform(union: union, origin: origin, scale: scale)
    }

    func arrangementItems() -> [ArrangementItem] {
        arrangementItems(offsets: machineOffsets)
    }

    private func arrangementItems(offsets: [String: CGPoint]) -> [ArrangementItem] {
        let macDefaults = defaultFrames(for: macDisplays, machine: "mac", xOffset: 0)
        let windowsDefaults = defaultFrames(for: windowsDisplays, machine: "windows", xOffset: -(windowsGroupWidth() + 220))
        return macDefaults + windowsDefaults
    }

    private func defaultFrames(for displays: [DisplayInfo], machine: String, xOffset: CGFloat) -> [ArrangementItem] {
        guard !displays.isEmpty else { return [] }
        let union = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        return displays.enumerated().map { index, display in
            let origin = CGPoint(
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

    private func drawAnchors(for item: ArrangementItem, in rect: NSRect) {
        for edge in Edge.allCases {
            let point = anchorPoint(edge: edge, in: rect)
            let hit = AnchorHit(item: item, edge: edge, point: point)
            renderedAnchors.append(hit)
            let selected = isSelectedAnchor(hit)
            let pending = pendingAnchor.map { $0.item.id == item.id && $0.edge == edge } == true
            let color = selected ? NSColor.systemGreen : (pending ? NSColor.systemYellow : NSColor.controlAccentColor)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    private func drawAnchorLink() {
        guard let link = anchorLink,
              let macAnchor = renderedAnchors.first(where: { $0.item.id == link.macItemId && $0.edge == link.macEdge }),
              let windowsAnchor = renderedAnchors.first(where: { $0.item.id == link.windowsItemId && $0.edge == link.windowsEdge })
        else { return }

        NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath()
        path.move(to: macAnchor.point)
        path.line(to: windowsAnchor.point)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawPendingAnchor(_ anchor: AnchorHit) {
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: anchor.point.x - 8, y: anchor.point.y - 8, width: 16, height: 16))
        path.lineWidth = 2
        path.stroke()
    }

    private func isSelectedAnchor(_ anchor: AnchorHit) -> Bool {
        guard let link = anchorLink else { return false }
        if anchor.item.machine == "mac" {
            return anchor.item.id == link.macItemId && anchor.edge == link.macEdge
        }
        return anchor.item.id == link.windowsItemId && anchor.edge == link.windowsEdge
    }

    private func anchorPoint(edge: Edge, in rect: NSRect) -> CGPoint {
        switch edge {
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.minY)
        }
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
        guard let hit = renderedAnchors.min(by: {
            distance($0.point, point) < distance($1.point, point)
        }), distance(hit.point, point) <= 14 else {
            pendingAnchor = nil
            needsDisplay = true
            return
        }

        if let pendingAnchor, pendingAnchor.item.machine != hit.item.machine {
            let mac = pendingAnchor.item.machine == "mac" ? pendingAnchor : hit
            let windows = pendingAnchor.item.machine == "windows" ? pendingAnchor : hit
            let link = ArrangementAnchorLink(
                macItemId: mac.item.id,
                macEdge: mac.edge,
                windowsItemId: windows.item.id,
                windowsEdge: windows.edge
            )
            anchorLink = link
            self.pendingAnchor = nil
            onAnchorLinkChanged?(link)
        } else {
            pendingAnchor = hit
        }
        needsDisplay = true
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
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
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        text.draw(at: point, withAttributes: attrs)
    }
}
