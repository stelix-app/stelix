// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Testing
@testable import StelixCore

struct SoloMemoryTests {
    private func switches(_ mix: StemMix) -> [Stem: Bool] {
        mix.controls.mapValues(\.enabled)
    }

    private func allOff(_ stems: [Stem]) -> StemMix {
        var mix = StemMix.allOn(stems)
        for stem in stems { mix.controls[stem]?.enabled = false }
        return mix
    }

    @Test func holdSolosTheStem() {
        var memory = SoloMemory()
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.volume = 0.6
        let solo = memory.hold(.drums, in: mix)
        #expect(solo.soloStem == .drums)
        #expect(solo.controls[.bass]?.volume == 0.6)
    }

    @Test func holdAgainRestoresPreviousSwitches() {
        var memory = SoloMemory()
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.enabled = false
        let solo = memory.hold(.drums, in: mix)
        #expect(memory.hold(.drums, in: solo) == mix)
    }

    @Test func holdAgainRestoresSwitchesAndKeepsVolumes() {
        var memory = SoloMemory()
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.enabled = false
        var solo = memory.hold(.drums, in: mix)
        solo.controls[.drums]?.volume = 0.3
        let back = memory.hold(.drums, in: solo)
        #expect(switches(back) == switches(mix))
        #expect(back.controls[.drums]?.volume == 0.3)
    }

    @Test func holdAgainFromAllOffRestoresAllOff() {
        var memory = SoloMemory()
        let off = allOff(Stem.studio)
        let solo = memory.hold(.vocals, in: off)
        #expect(solo.soloStem == .vocals)
        #expect(memory.hold(.vocals, in: solo) == off)
    }

    @Test func holdAgainAfterForgetTurnsAllOn() {
        var memory = SoloMemory()
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.enabled = false
        let solo = memory.hold(.drums, in: mix)
        memory.forget()
        #expect(memory.hold(.drums, in: solo) == StemMix.allOn(Stem.live))
    }

    @Test func holdOnSoloStemWithoutMemoryTurnsAllOn() {
        var memory = SoloMemory()
        let solo = StemMix.allOn(Stem.live).soloing(.bass)
        #expect(memory.hold(.bass, in: solo) == StemMix.allOn(Stem.live))
    }

    @Test func holdOtherStemMovesSolo() {
        var memory = SoloMemory()
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.enabled = false
        let drumsSolo = memory.hold(.drums, in: mix)
        let vocalsSolo = memory.hold(.vocals, in: drumsSolo)
        #expect(vocalsSolo.soloStem == .vocals)
        // The memory is that of the last hold: the drums solo, not the mix before it.
        #expect(memory.hold(.vocals, in: vocalsSolo) == drumsSolo)
    }

    @Test func holdAbsentStemChangesNothing() {
        var memory = SoloMemory()
        let mix = StemMix.allOn(Stem.live)
        #expect(memory.hold(.piano, in: mix) == mix)
    }
}
