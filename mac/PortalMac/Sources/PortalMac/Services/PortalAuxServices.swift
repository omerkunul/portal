import AppKit
import Darwin

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
