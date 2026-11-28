# YEnc

The yEnc decoder `UsenetYEnc` uses for Usenet articles on ARM64 (NEON).

- `common.h`, `hedley.h`, `platform.cc`, `decoder.h`, `decoder.cc`, `decoder_common.h`,
  `decoder_neon64.cc`: unchanged from
  [animetosho/node-yencode](https://github.com/animetosho/node-yencode) at
  `836ed11f8e079e43ca1980bf8de1e48afe2b4fc1`, Public Domain / CC0. Only the files its ARM64
  decoder needs (no encoder, no CRC: the CRC comes from zlib).
- `NuvioYEnc.h`, `NuvioYEnc.cc`: the C functions Swift calls through the bridging header.

Not built for x86_64 (`EXCLUDED_SOURCE_FILE_NAMES` in `Project.swift`); there `UsenetYEnc`
decodes a byte at a time.
