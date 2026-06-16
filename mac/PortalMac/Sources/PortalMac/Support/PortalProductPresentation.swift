import SwiftUI

enum PortalChecklistState: Equatable {
    case done
    case current
    case pending
}

struct PortalChecklistItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let state: PortalChecklistState
}

struct PortalOverviewCard: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let symbol: String
}

struct PortalProductFacts {
    let isRunning: Bool
    let isStarting: Bool
    let status: String
    let ipAddress: String
    let accessibilityLabel: String
    let accessibilityOK: Bool
    let awdlEnabled: Bool
    let awdlLabel: String
    let windowsSetupStatus: String
    let isServingInstaller: Bool
    let windowsHostCount: Int
    let arrangementSummary: String

    init(
        isRunning: Bool,
        isStarting: Bool,
        status: String,
        ipAddress: String,
        accessibilityLabel: String,
        accessibilityOK: Bool,
        awdlEnabled: Bool,
        awdlLabel: String,
        windowsSetupStatus: String,
        isServingInstaller: Bool,
        windowsHostCount: Int,
        arrangementSummary: String
    ) {
        self.isRunning = isRunning
        self.isStarting = isStarting
        self.status = status
        self.ipAddress = ipAddress
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityOK = accessibilityOK
        self.awdlEnabled = awdlEnabled
        self.awdlLabel = awdlLabel
        self.windowsSetupStatus = windowsSetupStatus
        self.isServingInstaller = isServingInstaller
        self.windowsHostCount = windowsHostCount
        self.arrangementSummary = arrangementSummary
    }

    init(model: PortalUIModel) {
        self.init(
            isRunning: model.isRunning,
            isStarting: model.isStarting,
            status: model.status,
            ipAddress: model.ip,
            accessibilityLabel: model.accessibility,
            accessibilityOK: model.accessibilityOK,
            awdlEnabled: model.awdlEnabled,
            awdlLabel: model.awdlText,
            windowsSetupStatus: model.windowsSetupStatus,
            isServingInstaller: model.isServingInstaller,
            windowsHostCount: model.windowsHosts.count,
            arrangementSummary: model.arrangement
        )
    }
}

struct PortalProductSnapshot {
    let headline: String
    let subheadline: String
    let statusBadge: String
    let primaryActionTitle: String
    let overviewCards: [PortalOverviewCard]
    let checklist: [PortalChecklistItem]
    let windowsReady: Bool

    init(facts: PortalProductFacts) {
        let windowsReady = PortalProductSnapshot.windowsReady(facts: facts)
        self.windowsReady = windowsReady

        if facts.isStarting {
            headline = "Starting Portal"
            subheadline = "Portal is preparing this Mac for low-latency keyboard and mouse control."
            statusBadge = "Starting"
        } else if !facts.accessibilityOK {
            headline = "Finish setup on this Mac"
            subheadline = "Portal needs Accessibility access before it can receive input from your Windows companion."
            statusBadge = "Needs Access"
        } else if facts.isRunning {
            headline = "Portal is ready"
            subheadline = "This Mac is listening on \(facts.ipAddress) and can take control as soon as your Windows app connects."
            statusBadge = "Ready"
        } else {
            headline = "Start Portal on this Mac"
            subheadline = "Portal is configured and ready to listen on \(facts.ipAddress) when you turn it on."
            statusBadge = "Stopped"
        }

        primaryActionTitle = facts.isRunning ? "Stop Portal" : "Start Portal"

        let portalCard = PortalOverviewCard(
            id: "portal",
            title: "Portal",
            value: facts.isRunning ? "On" : (facts.isStarting ? "Starting" : "Off"),
            detail: facts.status,
            symbol: facts.isRunning ? "dot.radiowaves.left.and.right" : "power"
        )
        let accessibilityCard = PortalOverviewCard(
            id: "accessibility",
            title: "Accessibility",
            value: facts.accessibilityOK ? "Granted" : "Required",
            detail: facts.accessibilityOK ? "macOS can forward mouse and keyboard input." : "Needed once before Portal can control this Mac.",
            symbol: "hand.raised"
        )
        let lowLatencyCard = PortalOverviewCard(
            id: "latency",
            title: "Low latency",
            value: facts.awdlEnabled ? "Standard" : "Optimized",
            detail: facts.awdlLabel,
            symbol: facts.awdlEnabled ? "wifi" : "bolt.horizontal"
        )
        let windowsCard = PortalOverviewCard(
            id: "windows",
            title: "Windows app",
            value: windowsReady ? "Connected" : "Setup required",
            detail: facts.windowsSetupStatus,
            symbol: "desktopcomputer"
        )

        overviewCards = facts.accessibilityOK
            ? [portalCard, lowLatencyCard, windowsCard]
            : [accessibilityCard, portalCard, windowsCard]

        checklist = [
            PortalChecklistItem(
                id: "accessibility",
                title: "Grant Accessibility access",
                detail: facts.accessibilityOK ? "Portal already has the permission it needs." : "Open System Settings once and allow Portal in Accessibility.",
                state: facts.accessibilityOK ? .done : .current
            ),
            PortalChecklistItem(
                id: "runtime",
                title: "Start Portal on this Mac",
                detail: facts.isRunning ? "Portal is actively listening for your Windows companion." : "Turn Portal on before you move your pointer across.",
                state: facts.isRunning ? .done : (facts.accessibilityOK ? .current : .pending)
            ),
            PortalChecklistItem(
                id: "windows",
                title: "Prepare the Windows companion",
                detail: windowsReady ? facts.windowsSetupStatus : "Share the installer or scan the LAN to get a Windows machine ready.",
                state: windowsReady ? .done : (facts.accessibilityOK && facts.isRunning ? .current : .pending)
            )
        ]
    }

    private static func windowsReady(facts: PortalProductFacts) -> Bool {
        if facts.windowsHostCount > 0 {
            return true
        }
        let lowercased = facts.windowsSetupStatus.lowercased()
        return lowercased.contains("connected")
    }
}
