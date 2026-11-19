// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

import Accelerate

/// Estimates how late one signal is relative to another, with FFT cross-correlation.
/// Used by `debugMeasureDelay`: tap input against mixed output.
public enum DelayEstimator {
    /// The delay (in frames, `0...maxLag`) that maximizes `Σ reference[t] · delayed[t + lag]`, with
    /// `score` = correlation normalized at that delay (1 = same shape). `nil` if either one is mute.
    public static func lag(reference: [Float], delayed: [Float], maxLag: Int) -> (lag: Int, score: Float)? {
        let n = min(reference.count, delayed.count)
        guard n > 1 else { return nil }
        var energyX: Float = 0, energyY: Float = 0
        vDSP_svesq(reference, 1, &energyX, vDSP_Length(n))
        vDSP_svesq(delayed, 1, &energyY, vDSP_Length(n))
        guard energyX > 0, energyY > 0 else { return nil }

        var log2n = 1
        while (1 << log2n) < 2 * n { log2n += 1 }   // zero-pad to 2n: no circular wrap-around
        let size = 1 << log2n
        let half = size / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        func spectrum(_ signal: [Float]) -> (re: [Float], im: [Float]) {
            var padded = [Float](repeating: 0, count: size)
            padded.replaceSubrange(0..<n, with: signal[0..<n])
            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }

        let x = spectrum(reference)
        let y = spectrum(delayed)
        // conj(X) · Y. In the packed format, index 0 holds DC (re) and Nyquist (im), both real.
        var cr = [Float](repeating: 0, count: half)
        var ci = [Float](repeating: 0, count: half)
        cr[0] = x.re[0] * y.re[0]
        ci[0] = x.im[0] * y.im[0]
        for k in 1..<half {
            cr[k] = x.re[k] * y.re[k] + x.im[k] * y.im[k]
            ci[k] = x.re[k] * y.im[k] - x.im[k] * y.re[k]
        }
        var corr = [Float](repeating: 0, count: size)
        cr.withUnsafeMutableBufferPointer { rp in
            ci.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
                corr.withUnsafeMutableBufferPointer { cp in
                    cp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }

        let last = min(maxLag, n - 1)
        var best = 0
        for k in 0...last where corr[k] > corr[best] { best = k }

        // The score is computed directly, so it does not depend on the FFT scale.
        var dot: Float = 0
        reference.withUnsafeBufferPointer { xp in
            delayed.withUnsafeBufferPointer { yp in
                vDSP_dotpr(xp.baseAddress!, 1, yp.baseAddress! + best, 1, &dot, vDSP_Length(n - best))
            }
        }
        return (best, dot / (energyX * energyY).squareRoot())
    }
}
