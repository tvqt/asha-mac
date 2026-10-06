// G722.swift — Swift wrappers around the C G.722 codec in g722/.
//
// G.722 turns 16 kHz, 16-bit audio into 4 bits per sample, so every 2 input
// samples become 1 output byte. The C functions are visible here because
// build.sh passes -import-objc-header g722/g722_enc_dec.h to the compiler.
//
// The codec keeps memory between calls (its "state": filter history), so
// one encoder must be used for one continuous stream. Starting a new stream =
// make a new encoder. That matches ASHA's Start command, which tells the aid
// to "reset the codec".

import Foundation

final class G722Encoder {
    /// The C state struct. We allocate it ourselves: the vendored C code only
    /// allocates memory when built with G722_SUPPORT_MALLOC, which we don't use.
    private let state: UnsafeMutablePointer<g722_encode_state_t>

    init() {
        state = UnsafeMutablePointer<g722_encode_state_t>.allocate(capacity: 1)
        // rate 64000 = full-quality 8 bits per sample pair. options 0 = normal 16 kHz
        // input, unpacked bytes. Same as Android. init also zeroes the struct,
        // so no uninitialised memory is ever used.
        _ = g722_encode_init(state, 64000, 0)
    }

    deinit {
        // Free the memory we allocated. (Don't call g722_encode_release: it
        // calls C's free(), which must only free memory C's malloc() gave out.)
        state.deallocate()
    }

    /// Encode PCM samples (16-bit, 16 kHz, mono). The sample count must be even.
    /// Returns exactly samples.count / 2 bytes, or stops the program: a wrong
    /// size would desynchronise the stream, and that must never be sent.
    func encode(_ samples: [Int16]) -> [UInt8] {
        precondition(samples.count % 2 == 0, "G.722 needs an even number of samples")
        var out = [UInt8](repeating: 0, count: samples.count / 2)   // zero-filled, never garbage
        let n = g722_encode(state, &out, samples, Int32(samples.count))
        guard Int(n) == out.count else {
            fail("G.722 encoder returned \(n) bytes, expected \(out.count). Refusing to continue.")
        }
        return out
    }
}

/// Decoder: used ONLY by the offline self-test (g722check). Never in the audio path.
final class G722Decoder {
    private let state: UnsafeMutablePointer<g722_decode_state_t>

    init() {
        state = UnsafeMutablePointer<g722_decode_state_t>.allocate(capacity: 1)
        _ = g722_decode_init(state, 64000, 0)
    }
    deinit { state.deallocate() }

    /// Decode bytes back to samples (2 samples per byte).
    func decode(_ bytes: [UInt8]) -> [Int16] {
        var out = [Int16](repeating: 0, count: bytes.count * 2)
        // The last argument is an output gain where 65536 would be ×1.0. It's a
        // 16-bit value, so the maximum 0xFFFF is ×0.99998, i.e. effectively ×1.
        let n = g722_decode(state, &out, bytes, Int32(bytes.count), 0xFFFF)
        return Array(out.prefix(Int(n)))
    }
}
