import SwiftUI

private enum PortalPage: String, CaseIterable, Hashable {
    case general = "General"
    case layouts = "Layouts"
    case windows = "Windows App"
    case settings = "Settings"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layouts: return "square.split.2x2"
        case .windows: return "desktopcomputer.and.arrow.down"
        case .settings: return "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Start Portal and review setup health."
        case .layouts: return "Place the handoff edge between Windows and Mac."
        case .windows: return "Prepare and install the Windows companion."
        case .settings: return "Tune startup, sync, and system behavior."
        }
    }
}

struct MotionGraphRepresentable: NSViewRepresentable {
    let view: MotionGraphView

    func makeNSView(context: Context) -> MotionGraphView { view }
    func updateNSView(_ nsView: MotionGraphView, context: Context) {}
}

struct DisplayArrangementRepresentable: NSViewRepresentable {
    let view: DisplayArrangementView

    func makeNSView(context: Context) -> DisplayArrangementView { view }

    func updateNSView(_ nsView: DisplayArrangementView, context: Context) {
        nsView.needsDisplay = true
    }
}

struct PortalRootView: View {
    @ObservedObject var model: PortalUIModel
    @State private var selectedPage: PortalPage = .general

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
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topBar

                Group {
                    if selectedPage == .settings {
                        ScrollView {
                            pageContent
                        }
                    } else {
                        pageContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .background(Color.white)
        }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            content(for: selectedPage)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: 980, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var topBar: some View {
        HStack {
            Spacer()
            HStack(spacing: PortalChromeMetrics.tabSpacing) {
                ForEach(PortalPage.allCases, id: \.self) { page in
                    PortalTopTab(
                        page: page,
                        isSelected: selectedPage == page,
                        action: { selectedPage = page }
                    )
                }
            }
            Spacer()
        }
        .padding(.horizontal, PortalChromeMetrics.topBarHorizontalPadding)
        .padding(.vertical, PortalChromeMetrics.topBarVerticalPadding)
    }

    @ViewBuilder
    private func content(for page: PortalPage) -> some View {
        switch page {
        case .general:
            GeneralPage(
                model: model,
                snapshot: PortalProductSnapshot(facts: PortalProductFacts(model: model)),
                motionGraph: motionGraph,
                toggleServer: toggleServer,
                toggleAwdl: toggleAwdl,
                openWindowsPage: { selectedPage = .windows }
            )
        case .layouts:
            LayoutsPage(
                model: model,
                arrangementView: arrangementView,
                resetArrangement: resetArrangement
            )
        case .windows:
            WindowsPage(
                model: model,
                scanWindowsHosts: scanWindowsHosts,
                toggleInstallerServer: toggleInstallerServer,
                copyWindowsInstallCommand: copyWindowsInstallCommand
            )
        case .settings:
            PortalSettingsPage(
                model: model,
                toggleAwdl: toggleAwdl,
                openAccessibility: openAccessibility
            )
        }
    }
}

private struct PortalTopTab: View {
    let page: PortalPage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .medium))
                Text(page.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .frame(
                width: PortalChromeMetrics.tabWidth,
                height: PortalChromeMetrics.tabHeight,
                alignment: .center
            )
            .background(
                RoundedRectangle(cornerRadius: PortalChromeMetrics.tabCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.0001))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PortalChromeMetrics.tabCornerRadius, style: .continuous)
                    .strokeBorder(Color.clear, lineWidth: 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityElement()
        .accessibilityLabel(page.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: PortalUIModel
    let snapshot: PortalProductSnapshot
    let motionGraph: MotionGraphView
    let toggleServer: () -> Void
    let toggleAwdl: (Bool) -> Void
    let openWindowsPage: () -> Void

    private let topCardHeight: CGFloat = 206
    private let cardColumns = [
        GridItem(.flexible(minimum: 180), spacing: 16),
        GridItem(.flexible(minimum: 180), spacing: 16),
        GridItem(.flexible(minimum: 180), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                PortalSurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.headline)
                            .font(.system(size: 30, weight: .semibold))
                        Text(snapshot.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            PortalMetaChip(symbol: "network", text: model.ip)
                            PortalMetaChip(symbol: "circle.grid.cross", text: model.port)
                        }

                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                PortalSurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Guided setup")
                            .font(.title3.weight(.semibold))

                        ForEach(snapshot.checklist) { item in
                            PortalChecklistRow(item: item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: topCardHeight, alignment: .top)

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                PortalRuntimeCard(model: model, toggleServer: toggleServer)
                PortalLatencyCard(model: model, toggleAwdl: toggleAwdl)
                PortalWindowsCard(snapshot: snapshot, openWindowsPage: openWindowsPage)
            }

            PortalSurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Live activity")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(model.stats)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.965, green: 0.965, blue: 0.972))
                        .frame(height: 92)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct LayoutsPage: View {
    @ObservedObject var model: PortalUIModel
    let arrangementView: DisplayArrangementView
    let resetArrangement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PortalSurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        Text("Arrangement preview")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Button("Reset layout", action: resetArrangement)
                            .buttonStyle(.bordered)
                    }
                    Text(model.arrangement)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    DisplayArrangementRepresentable(view: arrangementView)
                        .frame(height: 360)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct WindowsPage: View {
    @ObservedObject var model: PortalUIModel
    let scanWindowsHosts: () -> Void
    let toggleInstallerServer: () -> Void
    let copyWindowsInstallCommand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PortalSurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Windows companion")
                                .font(.title3.weight(.semibold))
                            Text("Serve the installer over your local network or scan for Windows machines that are already reachable.")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        HStack(spacing: 10) {
                            Button(model.isServingInstaller ? "Stop sharing" : "Share installer", action: toggleInstallerServer)
                                .buttonStyle(.borderedProminent)
                            Button("Copy install command", action: copyWindowsInstallCommand)
                                .buttonStyle(.bordered)
                                .disabled(model.windowsInstallCommand.isEmpty)
                        }
                    }

                    PortalSplitValueRow(label: "Status", value: model.windowsSetupStatus)
                    PortalSplitValueRow(label: "Installer URL", value: model.windowsInstallerURL.isEmpty ? "Not sharing yet" : model.windowsInstallerURL, monospaced: true)

                    if !model.windowsInstallCommand.isEmpty {
                        Text(model.windowsInstallCommand)
                            .font(.caption.monospaced())
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.quaternary.opacity(0.45))
                            )
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                PortalSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("LAN scan")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Button(model.isScanningWindows ? "Scanning..." : "Scan network", action: scanWindowsHosts)
                                .buttonStyle(.bordered)
                                .disabled(model.isScanningWindows)
                        }

                        if model.windowsHosts.isEmpty {
                            Text("No Windows candidates found yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.windowsHosts.prefix(5)) { host in
                                PortalHostRow(host: host)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                PortalSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Recommended flow")
                            .font(.title3.weight(.semibold))

                        PortalChecklistRow(item: .init(
                            id: "share",
                            title: "Share the installer",
                            detail: "Turn on local sharing so a Windows machine can download the companion app.",
                            state: model.isServingInstaller ? .done : .current
                        ))
                        PortalChecklistRow(item: .init(
                            id: "run",
                            title: "Run the install command on Windows",
                            detail: "Use the copied PowerShell command once to install the companion.",
                            state: model.windowsInstallCommand.isEmpty ? .pending : .current
                        ))
                        PortalChecklistRow(item: .init(
                            id: "connect",
                            title: "Return here and confirm discovery",
                            detail: "Once Windows is visible on the network, Portal can hand off control cleanly.",
                            state: model.windowsHosts.isEmpty ? .pending : .done
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct PortalSettingsPage: View {
    @ObservedObject var model: PortalUIModel
    @AppStorage("portal.clipboardSync.enabled") private var clipboardSyncEnabled = true
    @AppStorage("portal.autoStart.enabled") private var autoStartEnabled = true
    @AppStorage("portal.autoUpdate.enabled") private var autoUpdateEnabled = false
    @AppStorage("portal.autoScan.enabled") private var autoScanEnabled = true
    @AppStorage("portal.reconnect.enabled") private var reconnectEnabled = true
    @AppStorage("portal.notifications.enabled") private var notificationsEnabled = true
    @AppStorage("portal.launchAtLogin.enabled") private var launchAtLoginEnabled = false
    @AppStorage("portal.debugLogs.enabled") private var debugLogsEnabled = false

    let toggleAwdl: (Bool) -> Void
    let openAccessibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                PortalSurfaceCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Behavior")
                            .font(.title3.weight(.semibold))
                            .padding(.bottom, 14)

                        PortalToggleRow(
                            title: "Launch at login",
                            subtitle: "Open Portal automatically when this Mac signs in.",
                            isOn: $launchAtLoginEnabled
                        )
                        PortalToggleRow(
                            title: "Start Portal when opened",
                            subtitle: "Bring the listener online without an extra click.",
                            isOn: $autoStartEnabled
                        )
                        PortalToggleRow(
                            title: "Scan network on Windows page",
                            subtitle: "Refresh nearby Windows machines when you open setup.",
                            isOn: $autoScanEnabled
                        )
                        PortalToggleRow(
                            title: "Auto reconnect",
                            subtitle: "Reconnect to the last Windows companion when possible.",
                            isOn: $reconnectEnabled,
                            showsDivider: false
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                PortalSurfaceCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Sync and diagnostics")
                            .font(.title3.weight(.semibold))
                            .padding(.bottom, 14)

                        PortalToggleRow(
                            title: "Copy and paste",
                            subtitle: "Sync clipboard text and images between Windows and Mac.",
                            isOn: $clipboardSyncEnabled
                        )
                        PortalToggleRow(
                            title: "Notifications",
                            subtitle: "Show status changes while Portal is running.",
                            isOn: $notificationsEnabled
                        )
                        PortalToggleRow(
                            title: "Update Windows helper automatically",
                            subtitle: "Keep the Windows side current when a new build is available.",
                            isOn: $autoUpdateEnabled
                        )
                        PortalToggleRow(
                            title: "Debug logs",
                            subtitle: "Keep verbose logs for diagnostics and tuning.",
                            isOn: $debugLogsEnabled,
                            showsDivider: false
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            PortalSurfaceCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("System access")
                        .font(.title3.weight(.semibold))

                    PortalSplitValueRow(label: "Accessibility", value: model.accessibilityOK ? "Granted" : "Required")
                    PortalSplitValueRow(label: "Low latency mode", value: model.awdlText)

                    HStack {
                        Toggle("Use low latency mode", isOn: Binding(get: { model.awdlEnabled }, set: toggleAwdl))
                        Spacer()
                        Button("Open Accessibility Settings", action: openAccessibility)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

private struct PortalSurfaceCard<Content: View>: View {
    var fillColor: Color = .white
    var borderColor: Color = Color.black.opacity(0.045)
    var borderWidth: CGFloat = 1
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
    }
}

private struct PortalStatusBadge: View {
    let text: String
    let isRunning: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isRunning ? Color.green.opacity(0.14) : Color.orange.opacity(0.14))
            )
            .foregroundStyle(isRunning ? Color.green : Color.orange)
    }
}

private struct PortalMetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.quaternary.opacity(0.55))
            )
    }
}

private struct PortalRuntimeCard: View {
    @ObservedObject var model: PortalUIModel
    let toggleServer: () -> Void

    var body: some View {
        PortalSurfaceCard(
            fillColor: .white,
            borderColor: Color.accentColor.opacity(0.85),
            borderWidth: 1.2
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PortalCardIcon(symbol: model.isRunning ? "dot.radiowaves.left.and.right" : "power")
                    Spacer()
                    Toggle("", isOn: runningBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(model.isStarting)
                }

                Text("Portal")
                    .font(.headline)
                Text(model.isRunning ? "On" : (model.isStarting ? "Starting" : "Off"))
                    .font(.system(size: 24, weight: .semibold))
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runningBinding: Binding<Bool> {
        Binding(
            get: { model.isRunning },
            set: { newValue in
                guard newValue != model.isRunning else { return }
                toggleServer()
            }
        )
    }
}

private struct PortalLatencyCard: View {
    @ObservedObject var model: PortalUIModel
    let toggleAwdl: (Bool) -> Void

    var body: some View {
        PortalSurfaceCard(fillColor: .white) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PortalCardIcon(symbol: "waveform.path.ecg")
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.awdlEnabled }, set: toggleAwdl))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Text("Low latency")
                    .font(.headline)
                Text(model.awdlEnabled ? "Standard" : "Optimized")
                    .font(.system(size: 24, weight: .semibold))
                Text(model.awdlText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PortalWindowsCard: View {
    let snapshot: PortalProductSnapshot
    let openWindowsPage: () -> Void

    var body: some View {
        PortalSurfaceCard(fillColor: .white) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PortalCardIcon(symbol: "desktopcomputer")
                    Spacer()
                    if snapshot.windowsReady {
                        Text("Connected")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.green.opacity(0.14))
                            )
                            .foregroundStyle(.green)
                    } else {
                        Button("Setup", action: openWindowsPage)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                }

                Text("Windows app")
                    .font(.headline)
                Text(snapshot.windowsReady ? "Connected" : "Setup required")
                    .font(.system(size: 24, weight: .semibold))
                Text(snapshot.overviewCards.last?.detail ?? "Open setup to prepare a Windows host.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PortalCardIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 20, height: 20, alignment: .leading)
    }
}

private struct PortalChecklistRow: View {
    let item: PortalChecklistItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(iconColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var iconName: String {
        switch item.state {
        case .done: return "checkmark"
        case .current: return "arrow.right"
        case .pending: return "circle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .done: return .green
        case .current: return .accentColor
        case .pending: return .secondary
        }
    }
}

private struct PortalSplitValueRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct PortalHostRow: View {
    let host: WindowsHostCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(host.name.isEmpty ? host.ip : host.name)
                    .font(.headline)
                Text(host.summary)
                    .foregroundStyle(.secondary)
                Text(host.ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }
}

private struct PortalToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.vertical, 12)

            if showsDivider {
                Divider()
            }
        }
    }
}
