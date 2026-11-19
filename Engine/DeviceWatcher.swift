// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import CoreAudio
import Foundation

/// Warns when the audio output changes: default device, nominal sample rate, channels or
/// format of the output streams, stereo pair. Events often arrive in a burst (AirPods change rate and
/// format together), so `onChange` fires only once, 300 ms after the last one. When the default
/// device itself changes the wait is 80 ms: for all that time the old device
/// would still play Live and the new one the original. Events that follow within 300 ms
/// are collected as usual, and `LiveEngine` rebuilds only if the output signature has changed.
///
/// When the default device changes, the listeners on the device move to the new one;
/// when its streams change, those on the streams' format are redone on the new ones.
final class DeviceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.stelix-app.stelix.engine.devices")
    private let onChange: @Sendable () -> Void
    private let debounce: DispatchTimeInterval = .milliseconds(300)
    private let deviceDebounce: DispatchTimeInterval = .milliseconds(80)
    /// The output streams of the followed device, with their `VirtualFormat` listeners.
    private var streams: [AudioObjectID] = []
    private var pending: DispatchWorkItem?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var invalidated = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        queue.sync {
            listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                guard let self else { return }
                let moved = self.followDefaultDevice()
                self.changed(after: moved ? self.deviceDebounce : self.debounce)
            }
            followDefaultDevice()
        }
    }

    deinit {
        // The listeners hold `self` weakly: removing them here is enough.
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    /// From here on it no longer calls `onChange`, even if an event is already queued.
    func invalidate() {
        queue.sync {
            invalidated = true
            pending?.cancel()
            pending = nil
        }
    }

    // On the `queue` queue.

    private func changed() {
        changed(after: debounce)
    }

    private func changed(after delay: DispatchTimeInterval) {
        guard !invalidated else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.invalidated else { return }
            self.onChange()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Listens to the rate, configuration and format of the streams of the current default device.
    /// `true` if the device has changed.
    @discardableResult
    private func followDefaultDevice() -> Bool {
        let current = CoreAudioProperty.defaultOutputDevice()
        guard current != device else { return false }
        removeListeners(on: device)
        streams = []
        device = current
        guard current != AudioObjectID(kAudioObjectUnknown) else { return true }
        listen(current, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.changed() }
        listen(current, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
            self?.changed()
        }
        listen(current, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
            self?.followStreams()
            self?.changed()
        }
        // The stereo pair of Configure Speakers decides where Live reads and writes.
        listen(current, kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
            self?.changed()
        }
        followStreams()
        return true
    }

    /// The `VirtualFormat` listeners on the device's current output streams: those on
    /// streams that no longer exist are removed, new ones are added.
    private func followStreams() {
        let current = CoreAudioProperty.streams(device, scope: kAudioObjectPropertyScopeOutput)
        guard current != streams else { return }
        let gone = Set(streams).subtracting(current)
        listeners.removeAll { object, address, block in
            guard gone.contains(object) else { return false }
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            return true
        }
        for stream in current where !streams.contains(stream) {
            listen(stream, kAudioStreamPropertyVirtualFormat) { [weak self] in self?.changed() }
        }
        streams = current
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ handler: @escaping @Sendable () -> Void) {
        var address = CoreAudioProperty.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    /// Removes the listeners of the old device and its streams (not the system ones).
    private func removeListeners(on old: AudioObjectID) {
        guard old != AudioObjectID(kAudioObjectUnknown) else { return }
        listeners.removeAll { object, address, block in
            guard object != AudioObjectID(kAudioObjectSystemObject) else { return false }
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            return true
        }
    }
}
