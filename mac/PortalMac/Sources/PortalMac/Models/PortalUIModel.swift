import SwiftUI

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
        return name.isEmpty ? portText : "\(portText) - \(name)"
    }
}

extension Color {
    static var portalOrange: Color { .orange }
    static var portalGreen: Color { .green }
}
