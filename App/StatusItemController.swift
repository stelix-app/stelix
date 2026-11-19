// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore

/// The icon in the menu bar. It changes with the state (`StatusIconState`): still in Original, three bars
/// in Live (a 10 Hz timer that exists only while Live plays), progress while the Studio
/// separates (on every `.job` event, no timer), and the same fill while a model downloads (also in
/// Original: it's the user's download, in twentieths), and a dot on the still icon while a newer
/// version waits (`UpdateCenter.showsDot`). The image is redrawn only if the state changes.
/// On macOS 27 the panel goes through
/// `expandedInterfaceDelegate`, which gives keyboard navigation and menu tracking; on macOS 26
/// a click on the button toggles.
@MainActor final class StatusItemController: NSObject {
    static let liveInterval: TimeInterval = 0.1

    private let item: NSStatusItem
    private let panel: PanelController
    private let controller: ModeController
    private let live: LiveViewModel
    private let studio: StudioViewModel
    private let library: ModelLibrary
    private let updates: UpdateCenter?
    private let renderer = StatusIconRenderer()
    private var shown: StatusIconState?
    private var timer: Timer?

    init(panel: PanelController, controller: ModeController, live: LiveViewModel, studio: StudioViewModel,
         library: ModelLibrary, updates: UpdateCenter?) {
        self.panel = panel
        self.library = library
        self.updates = updates
        self.controller = controller
        self.live = live
        self.studio = studio
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.image = renderer.update(for: .idle)
        shown = .idle
        observe()

        if #available(macOS 27, *) {
            item.expandedInterfaceDelegate = self
            panel.onHide = { [weak self] in self?.item.expandedInterfaceSession?.cancel() }
        } else {
            item.button?.target = self
            item.button?.action = #selector(toggle)
        }
    }

    /// The button's rectangle in screen coordinates, where the panel attaches.
    var anchor: NSRect {
        guard let button = item.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Opens the panel from code (`--open-panel`).
    func open() {
        panel.show(anchor: anchor)
    }

    // MARK: - Icon per state

    /// Reads again the section, phases and Studio stage, and rearms at the first change. The Live levels
    /// are not observed: the timer reads them, and it exists only when needed.
    private func observe() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func refresh() {
        if StatusIconState.animates(mode: controller.selected, phase: controller.phase, live: live.phase) {
            startTimer()
        } else {
            stopTimer()
            show(StatusIconState.make(
                mode: controller.selected, phase: controller.phase, live: live.phase,
                levels: [:], studio: studio.stage, download: library.download?.fraction,
                update: updates?.showsDot ?? false))
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        show(StatusIconState.make(
            mode: controller.selected, phase: controller.phase, live: live.phase,
            levels: live.levels, studio: studio.stage, download: library.download?.fraction,
            update: updates?.showsDot ?? false))
    }

    private func show(_ state: StatusIconState) {
        guard state != shown else { return }
        shown = state
        item.button?.image = renderer.update(for: state)
    }

    @objc private func toggle() {
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show(anchor: anchor)
        }
    }
}

@available(macOS 27, *)
extension StatusItemController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        panel.show(anchor: anchor)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        panel.hide()
    }
}
