// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Foundation
import Testing
@testable import StelixCore

struct StemMixTests {
    @Test func soloVoiceKeepsVolumes() {
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.drums]?.volume = 0.5
        let solo = mix.applying(.soloVoice)
        #expect(solo.controls[.vocals]?.enabled == true)
        #expect(solo.controls[.drums]?.enabled == false)
        #expect(solo.controls[.bass]?.enabled == false)
        #expect(solo.controls[.other]?.enabled == false)
        #expect(solo.controls[.drums]?.volume == 0.5)
    }

    @Test func noVoiceDisablesOnlyVocals() {
        let mix = StemMix.allOn(Stem.live).applying(.noVoice)
        #expect(mix.controls[.vocals]?.enabled == false)
        #expect(mix.controls[.drums]?.enabled == true)
        #expect(mix.controls[.bass]?.enabled == true)
        #expect(mix.controls[.other]?.enabled == true)
    }

    @Test func allEnablesEverything() {
        let mix = StemMix.allOn(Stem.studio).applying(.soloVoice).applying(.all)
        for stem in Stem.studio {
            #expect(mix.controls[stem]?.enabled == true)
        }
        #expect(mix.controls.count == 6)
    }

    @Test func effectiveGainZeroWhenDisabledOrMissing() {
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.bass]?.volume = 0.7
        #expect(mix.effectiveGain(.bass) == 0.7)
        mix.controls[.bass]?.enabled = false
        #expect(mix.effectiveGain(.bass) == 0)
        #expect(mix.effectiveGain(.piano) == 0)
    }

    @Test func matchingPresetDetectsSoloVoice() {
        let base = StemMix.allOn(Stem.live)
        #expect(base.matchingPreset == .all)
        #expect(base.applying(.soloVoice).matchingPreset == .soloVoice)
        #expect(base.applying(.noVoice).matchingPreset == .noVoice)
        var voiceAndBass = base.applying(.soloVoice)
        voiceAndBass.controls[.bass]?.enabled = true
        #expect(voiceAndBass.matchingPreset == nil)
    }

    @Test func soloingKeepsVolumesAndTurnsOthersOff() {
        var mix = StemMix.allOn(Stem.live)
        mix.controls[.drums]?.volume = 0.5
        mix.controls[.vocals]?.enabled = false
        let solo = mix.soloing(.vocals)
        #expect(solo.controls[.vocals]?.enabled == true)
        #expect(solo.controls[.drums]?.enabled == false)
        #expect(solo.controls[.bass]?.enabled == false)
        #expect(solo.controls[.other]?.enabled == false)
        #expect(solo.controls[.drums]?.volume == 0.5)
    }

    @Test func soloingAbsentStemChangesNothing() {
        #expect(StemMix.allOn(Stem.live).soloing(.piano) == StemMix.allOn(Stem.live))
    }

    @Test func soloStemOnlyWhenExactlyOneIsOn() {
        let all = StemMix.allOn(Stem.live)
        #expect(all.soloStem == nil)
        #expect(all.soloing(.bass).soloStem == .bass)
        var none = all
        for stem in Stem.live { none.controls[stem]?.enabled = false }
        #expect(none.soloStem == nil)
        var two = all.soloing(.bass)
        two.controls[.drums]?.enabled = true
        #expect(two.soloStem == nil)
    }

    @Test func soloOfVocalsMatchesVocalsOnly() {
        #expect(StemMix.allOn(Stem.studio).soloing(.vocals).matchingPreset == .soloVoice)
    }

    @Test func levelsMatchMeasuredTable() {
        // values measured on an M3 Max (htdemucs p95 161.7 ms)
        #expect(abs(LiveLevel.intermediate.targetDelay - 1.0) < 1e-9)
        #expect(abs(LiveLevel.base.targetDelay - 0.65) < 1e-9)
        #expect(abs(LiveLevel.pro.targetDelay - 3.20) < 1e-9)
        #expect(LiveLevel.base.hop == 0.30)
        #expect(LiveLevel.pro.hop == 1.05)
        // The ML thread must finish within the margin, and htdemucs has p95 0.162 s.
        #expect(LiveLevel.intermediate.lookahead == 0.25)
        #expect(LiveLevel.intermediate.margin == 0.25)
        for level in LiveLevel.allCases { #expect(level.margin >= 0.25) }
        for level in LiveLevel.allCases { #expect(level.lookahead >= 0.1) }
        #expect(LiveLevel.pro.modelName == "htdemucs_ft")
        #expect(LiveLevel.intermediate.modelName == "htdemucs")
    }

    @Test func stemMixRoundTripsJSON() throws {
        var mix = StemMix.allOn(Stem.live).applying(.noVoice)
        mix.controls[.other]?.volume = 0.25
        let data = try JSONEncoder().encode(mix)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"vocals\""))
        let decoded = try JSONDecoder().decode(StemMix.self, from: data)
        #expect(decoded == mix)
    }

    /// The visible names are given by the app; inside, the stem files are named in English.
    @Test func stemOrderAndInternalFileNames() {
        #expect(Stem.live == [.vocals, .drums, .bass, .other])
        #expect(Stem.studio == [.vocals, .piano, .guitar, .bass, .drums, .other])
        #expect(Stem.guitar.fileName == "guitar.wav")
    }
}
