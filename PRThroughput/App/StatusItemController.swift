import AppKit
import Combine
import SwiftUI

enum StatusItemPresentation: Equatable {
    case disconnected
    case syncing
    case assignedCount
    case approved
    case merged

    static func resolve(
        transient: TransientEventKind?,
        connectionState: AppModel.ConnectionState,
        hasVerifiedSnapshot: Bool
    ) -> Self {
        switch transient {
        case .approved: .approved
        case .merged: .merged
        case nil where connectionState != .connected: .disconnected
        case nil where !hasVerifiedSnapshot: .syncing
        case nil: .assignedCount
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private static let autosaveName = "PRThroughputStatusItem"
    private static let initialPositionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let legacySystemControlPosition = 40
    private static let initialThirdPartyAppPosition = 500

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var modelObservation: AnyCancellable?
    private var layoutObservation: AnyCancellable?
    private var showsPrimaryIcon = true
    private var measuredFullWidth: CGFloat = 44

    init(model: AppModel) {
        let defaults = UserDefaults.standard
        let savedPosition = defaults.object(forKey: Self.initialPositionKey) as? Int
        if savedPosition == nil || savedPosition == Self.legacySystemControlPosition {
            // Keep PR Throughput with third-party status items, to the left of
            // Spotlight, Wi-Fi, battery, and Control Center. Migrate only our old
            // forced value so a position chosen later with Command-drag is preserved.
            defaults.set(Self.initialThirdPartyAppPosition, forKey: Self.initialPositionKey)
        }
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = Self.autosaveName
        statusItem.isVisible = true
        configurePopover()
        configureButton()
        updateButton()

        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        layoutObservation = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateLayoutForAvailableSpace() }
            }
        DispatchQueue.main.async { [weak self] in self?.updateLayoutForAvailableSpace() }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 580)
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView(model: model))
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.alignment = .center
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }

        switch StatusItemPresentation.resolve(
            transient: model.transientKind,
            connectionState: model.connectionState,
            hasVerifiedSnapshot: model.snapshot != nil && model.isDataVerified
        ) {
        case .approved:
            setSymbol("checkmark.seal.fill", on: button)
        case .merged:
            setSymbol("arrow.triangle.merge", on: button)
        case .assignedCount:
            setAssignedCount(on: button)
        case .syncing:
            setSymbol("arrow.clockwise", on: button)
        case .disconnected:
            setSymbol("arrow.trianglehead.branch", on: button)
        }

        button.toolTip = "PR Throughput — \(accessibilitySummary)"
        button.setAccessibilityLabel("PR Throughput")
        button.setAccessibilityValue(accessibilitySummary)
    }

    private func setSymbol(_ name: String, on button: NSStatusBarButton) {
        statusItem.length = NSStatusItem.squareLength
        button.attributedTitle = NSAttributedString(string: "")
        button.image = whiteSymbol(named: name)
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
    }

    private func setAssignedCount(on button: NSStatusBarButton) {
        let count = "\(model.assignedCount)"
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: count.count >= 3 ? 11 : NSFont.systemFontSize,
            weight: .regular
        )
        let title = NSMutableAttributedString(
            string: count,
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        if !model.unseenItems.isEmpty {
            let dotColor = model.unseenItems.compactMap(\.highestPriorityUnseenApplication).min {
                if $0.ruleID.priority != $1.ruleID.priority { return $0.ruleID.priority < $1.ruleID.priority }
                return $0.appliedAt > $1.appliedAt
            }.flatMap { NSColor(actionHex: $0.colorHex) } ?? .systemRed
            title.append(NSAttributedString(
                string: "  ●",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: dotColor,
                    .baselineOffset: 1
                ]
            ))
        }
        button.attributedTitle = title
        button.contentTintColor = nil

        if showsPrimaryIcon {
            statusItem.length = NSStatusItem.variableLength
            button.image = whiteSymbol(named: "arrow.trianglehead.branch")
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        } else {
            // Keep enough intrinsic width for the complete count, including 3+ digits.
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    private func whiteSymbol(named name: String) -> NSImage? {
        let size = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        let color = NSImage.SymbolConfiguration(paletteColors: [.white])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(size.applying(color))
        image?.isTemplate = false
        return image
    }

    private func updateLayoutForAvailableSpace() {
        guard model.connectionState == .connected,
              model.transientKind == nil,
              let button = statusItem.button,
              let window = button.window,
              let screen = window.screen,
              let safeRightArea = screen.auxiliaryTopRightArea else { return }

        if showsPrimaryIcon {
            measuredFullWidth = max(measuredFullWidth, window.frame.width)
        }
        let proposedFullFrameMinX = window.frame.maxX - measuredFullWidth
        let fullLabelFits = proposedFullFrameMinX >= safeRightArea.minX + 2
            && window.frame.maxX <= safeRightArea.maxX + 2

        guard fullLabelFits != showsPrimaryIcon else { return }
        showsPrimaryIcon = fullLabelFits
        updateButton()
    }

    private var accessibilitySummary: String {
        guard model.connectionState == .connected else { return "GitHub disconnected" }
        guard model.snapshot != nil, model.isDataVerified else {
            return "Syncing GitHub history; verified totals are not yet available"
        }
        let attentionCount = model.unseenItems.count
        let assigned = "\(model.assignedCount) open pull requests assigned to you"
        guard attentionCount > 0 else { return assigned }
        let highest = model.unseenItems.compactMap(\.highestPriorityUnseenApplication)
            .min { $0.ruleID.priority < $1.ruleID.priority }?.labelName
        return "\(assigned), \(attentionCount) unseen action\(attentionCount == 1 ? "" : "s")\(highest.map { ", highest priority \($0)" } ?? "")"
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverWillShow(_ notification: Notification) {
        model.setPopoverPresented(true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPopoverPresented(false)
    }
}

private extension NSColor {
    convenience init?(actionHex: String) {
        guard actionHex.count == 6, let value = Int(actionHex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
