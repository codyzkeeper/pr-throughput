import AppKit
import Combine
import SwiftUI

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

        switch model.transientKind {
        case .approved:
            setSymbol("checkmark.seal.fill", on: button)
        case .merged:
            setSymbol("arrow.triangle.merge", on: button)
        case nil where model.connectionState == .connected:
            setAssignedCount(on: button)
        case nil:
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
            title.append(NSAttributedString(
                string: "  ●",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: NSColor.systemRed,
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
        let attentionCount = model.unseenItems.count
        let assigned = "\(model.assignedCount) open pull requests assigned to you"
        guard attentionCount > 0 else { return assigned }
        return "\(assigned), \(attentionCount) unseen direct mention\(attentionCount == 1 ? "" : "s")"
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
