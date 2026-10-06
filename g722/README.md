# G.722 codec (vendored)

G.722 is the ITU audio codec (coder/decoder, i.e. compression scheme) that ASHA uses.
It squeezes 16 kHz, 16-bit audio (256 kbit/s) into 64 kbit/s: 4 bits per sample, so
every 2 input samples become 1 output byte.

## Where these files come from
Fetched 2026-10-06 from the Android Open Source Project, Bluetooth module:
`android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/system/embdrv/g722/`

| here              | upstream          |
|-------------------|-------------------|
| g722_encode.c     | g722_encode.cc    |
| g722_decode.c     | g722_decode.cc    |
| g722_enc_dec.h    | g722_enc_dec.h    |
| g722_typedefs.h   | g722_typedefs.h   |

The upstream files are plain C despite the `.cc` extension. We renamed them to `.c` so clang
compiles them as C. Apart from that, they are **unmodified**.

Why this copy? It is the exact encoder Android uses to stream ASHA to hearing aids,
including Oticon Real aids streaming from a Pixel phone. So its output is known to be
accepted by real ASHA devices.

## Licence
SpanDSP code by Steve Underwood, who placed his contributions in the public domain (see
the file headers). It is based on G.722 code © CMU 1993 (Chengxiang Lu and Alex Hauptmann).
The same code also ships in asha_pipewire_sink (public domain/Unlicense) and in AOSP.

## Use in this project
- `g722_encode()`: used by the streaming tools.
- `g722_decode()`: used ONLY by the offline self-test (`g722check`), to check the encoder's
  output decodes back to the original tone. It is never used for anything sent to the aids.
