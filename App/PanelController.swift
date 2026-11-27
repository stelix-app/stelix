// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// A borderless `NSPanel` must be able to become key, otherwise Esc and ⌘Q do not arrive.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The window content clipped to the glass corners. `NSGlassEffectView` rounds only
/// its drawing: without the clip the window stays a 360 pt rectangle, and the window server
/// computes shadow and border on it (the sharp-cornered rectangle under the corners).
final class RoundedClipView: NSView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) non usato") }

    override var isOpaque: Bool { false }
}

/// The panel under the menu bar icon. The SwiftUI view exists only while the panel is open:
/// si crea in `show()` e si distrugge in `hide()`.
@MainActor final class PanelController {
    static let width: CGFloat = 360
    static let cornerRadius: CGFloat = 20
    private static let gap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    private let controller: ModeController
    private let live: LiveViewModel
    private let studio: StudioViewModel
    private let settings: SettingsModel
    private let models: ModelsModel
    private let updates: UpdateCenter?
    /// The app's preferences (a separate domain in `--snapshot`), also for the views' `@AppStorage`.
    private let defaults: UserDefaults
    private var panel: KeyablePanel?
    private var hosting: NSView?
    private var anchor: NSRect = .zero
    private var clickMonitor: Any?
    private var outsideClick = OutsideClick()
    private var keyMonitor: Any?

    /// Called when the panel closes by a way other than the menu bar (click outside, Esc).
    var onHide: (() -> Void)?

    var isVisible: Bool { hosting != nil }

    /// True while the Studio file picker is open: click outside and Esc do not close
    /// the panel (Esc goes to the picker).
    var holdOpen = false

    /// For `--snapshot`: no background glass, which `cacheDisplay` cannot draw.
    var plainBackground = false

    init(controller: ModeController, live: LiveViewModel, studio: StudioViewModel, settings: SettingsModel,
         models: ModelsModel, updates: UpdateCenter?, defaults: UserDefaults) {
        self.defaults = defaults
        self.controller = controller
        self.updates = updates
        self.live = live
        self.studio = studio
        self.settings = settings
        self.models = models
    }

    /// - Parameter anchor: the menu bar icon's rectangle, in screen coordinates.
    func show(anchor: NSRect) {
        self.anchor = anchor
        // Models can be added or removed in the Finder: a look at the files is cheap.
        models.library.refresh()
        guard hosting == nil else {
            reposition()
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let root = PanelRoot(controller: controller, live: live, studio: studio, settings: settings,
                             models: models, updates: updates) { [weak self] size in
            self?.resize(to: size)
        }
        let hostingView = NSHostingView(rootView: root.defaultAppStorage(defaults))
        if plainBackground {
            // The PNG has a white background: light appearance, otherwise with the Mac in dark mode the text disappears.
            panel.appearance = NSAppearance(named: .aqua)
            panel.contentView = hostingView
        } else {
            let background = makePanelBackground(content: hostingView, cornerRadius: Self.cornerRadius)
            let clip = RoundedClipView(radius: Self.cornerRadius)
            background.frame = clip.bounds
            background.autoresizingMask = [.width, .height]
            clip.addSubview(background)
            panel.contentView = clip
        }
        hosting = hostingView

        resize(to: hostingView.fittingSize)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Becoming key, AppKit gives the focus to the first view that takes it: the transpose field, all
        // selected. The panel opens with nothing focused; a click in the field focuses it.
        panel.makeFirstResponder(nil)
        installMonitors()
        live.setPanelOpen(true)
        studio.setPanelOpen(true)
    }

    func hide() {
        guard hosting != nil else { return }
        removeMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
        hosting = nil
        live.setPanelOpen(false)
        studio.setPanelOpen(false)
        settings.close()
        controller.panelClosed()
        onHide?()
    }

    /// The panel content as PNG (for `--snapshot`). The glass may be missing, the layout not.
    func renderPNG() -> Data? {
        guard let view = hosting, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Finestra

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private var size: CGSize = .zero

    private func resize(to newSize: CGSize) {
        guard newSize.height > 0 else { return }
        size = CGSize(width: Self.width, height: ceil(newSize.height))
        reposition()
    }

    /// Top edge attached under the icon, centered on it, inside the screen.
    private func reposition() {
        guard let panel, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
        let top = min(anchor.minY, visible.maxY) - Self.gap
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        // The shadow is computed on the drawn shape: after a height change it must be redone, on the next turn,
        // when the resized content is already drawn.
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
    }

    // MARK: - Closing: click outside (not a drag), Esc; ⌘Q quits

    private func installMonitors() {
        // A drag that starts outside (a file from Finder toward the Studio) does not close the panel.
        outsideClick = OutsideClick()
        let mice: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mice) { [weak self] event in
            let mouse: OutsideClick.Mouse
            switch event.type {
            case .leftMouseDown: mouse = .leftDown
            case .leftMouseDragged: mouse = .leftDragged
            case .leftMouseUp: mouse = .leftUp
            default: mouse = .rightDown
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                let close = self.outsideClick.handle(mouse)
                if close, !self.holdOpen { self.hide() }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let isCommandOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            let key = event.charactersIgnoringModifiers
            let isRepeat = event.isARepeat
            let plainSpace = keyCode == 49
                && event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).isEmpty
            let consumed = MainActor.assumeIsolated { () -> Bool in
                // Space plays and pauses the Studio, as in Logic, wherever the focus is; not while typing
                // (a text field), with the file picker or the settings open, or with VoiceOver's modifiers.
                if plainSpace, let self, !self.holdOpen, !self.settings.isOpen, self.controller.selected == .studio,
                   !(self.panel?.firstResponder is NSText) {
                    return self.studio.spaceKey(isRepeat: isRepeat)
                }
                // Esc: a field being typed in first (the transpose drops the edit), then settings, then the panel.
                if keyCode == 53, self?.holdOpen == false, !(self?.panel?.firstResponder is NSText) {
                    if self?.settings.isOpen == true {
                        self?.settings.close()
                    } else {
                        self?.hide()
                    }
                    return true
                }
                if isCommandOnly, key == "q" {
                    NSApp.terminate(nil)
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }
}

extension PanelController: PanelHolding {
    var windowLevel: NSWindow.Level { panel?.level ?? .statusBar }

    func reopen() {
        if isVisible {
            panel?.makeKey()
        } else {
            show(anchor: anchor)
        }
    }
}

/// Root of the hosting view: measures the content and reports it to the panel.
struct PanelRoot: View {
    let controller: ModeController
    let live: LiveViewModel
    let studio: StudioViewModel
    let settings: SettingsModel
    let models: ModelsModel
    let updates: UpdateCenter?
    let onSize: (CGSize) -> Void

    /// How much the content is short of the next whole point above (249.5 → 0.5 in Original).
    @State private var roundingPad: CGFloat = 0

    var body: some View {
        PanelView(controller: controller, live: live, studio: studio, settings: settings, models: models,
                  updates: updates)
            .frame(width: PanelController.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                roundingPad = ceil(size.height) - size.height
                onSize(size)
            }
            // Always a whole height. With half a point the hosting view brought the window back
            // to the exact height of the content, and AppKit resizes keeping the bottom edge
            // fixed: in Original (249.5 points) the panel dropped half a point.
            .padding(.bottom, roundingPad)
    }
}
