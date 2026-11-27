// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import AppKit
import StelixCore
import SwiftUI

/// The window of "Stelix 1.2.0 is available" (`UpdateWindow`), on the same glass as the panel.
/// `UpdateCenter.present` opens it: by itself in front of the other apps without taking the
/// keyboard, or active after a click in Settings. Its close button counts as Later
/// (`UpdateCenter.windowClosed`). Created once and reused.
///
/// Stelix has no menu bar of its own, so Esc and ⌘W (close, as the red button) and ⌘Q arrive here.
final class UpdateNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "w":
            performClose(nil)
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

@MainActor final class UpdateWindowController: NSObject, NSWindowDelegate {
    private static let cornerRadius: CGFloat = PanelController.cornerRadius

    private let updates: UpdateCenter
    private var window: NSWindow?
    /// The top edge stays where it is when the content grows or shrinks (download, ready…).
    private var size: CGSize = .zero

    init(updates: UpdateCenter) {
        self.updates = updates
    }

    func show(activating: Bool) {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            // Centered once, at its real height: afterwards it stays where the user put it.
            window = makeWindow()
            window.center()
        }
        if activating {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Later and Skip This Version: already put off, so the window just goes.
    /// Also when the version it shows is gone (no newer release any more): an empty window would stay.
    private func hide() {
        window?.orderOut(nil)
        giveBackKeyboard()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        updates.windowClosed()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.giveBackKeyboard() }
    }

    /// With the window gone and the panel closed, Stelix has nothing to type into: the app the
    /// user came from gets the keyboard back instead of nobody having it.
    private func giveBackKeyboard() {
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0 is KeyablePanel && $0.isVisible }) else { return }
        NSApp.deactivate()
    }

    private func makeWindow() -> NSWindow {
        let window = UpdateNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UpdateWindow.width, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        window.title = Copy.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // Over a full-screen app (a DAW) it opens there, not on another Space.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self

        let root = UpdateWindowRoot(
            updates: updates, language: Bundle.main.preferredLocalizations.first,
            close: { [weak self] in self?.hide() },
            onSize: { [weak self] size in self?.resize(to: size) })
        let hosting = NSHostingView(rootView: root)
        let background = makePanelBackground(content: hosting, cornerRadius: Self.cornerRadius)
        let clip = RoundedClipView(radius: Self.cornerRadius)
        background.frame = clip.bounds
        background.autoresizingMask = [.width, .height]
        clip.addSubview(background)
        window.contentView = clip
        self.window = window
        resize(to: hosting.fittingSize)
        return window
    }

    private func resize(to newSize: CGSize) {
        guard let window, newSize.height > 0 else { return }
        let height = ceil(newSize.height)
        guard height != size.height else { return }
        size = CGSize(width: UpdateWindow.width, height: height)
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = size
        window.setFrame(frame, display: true)
        DispatchQueue.main.async { [weak window] in window?.invalidateShadow() }
    }

    fileprivate static var contentInsets: EdgeInsets {
        // The title bar (traffic lights) is SwiftUI's top safe area, already above this inset.
        EdgeInsets(top: Tokens.spaceS, leading: Tokens.spaceXL,
                   bottom: Tokens.spaceXL, trailing: Tokens.spaceXL)
    }
}

/// Measures the window content and reports it, as `PanelRoot` does for the panel.
private struct UpdateWindowRoot: View {
    let updates: UpdateCenter
    let language: String?
    let close: () -> Void
    let onSize: (CGSize) -> Void

    var body: some View {
        UpdateWindow(updates: updates, language: language, close: close)
            .padding(UpdateWindowController.contentInsets)
            .frame(width: UpdateWindow.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}
