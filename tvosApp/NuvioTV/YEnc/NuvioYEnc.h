//
// NuvioYEnc.h
// node-yencode's yEnc decoder (NEON on ARM64), for UsenetYEnc: decodes an article's data at
// several GB/s, where a byte at a time manages about 650 MB/s on an Apple TV.
//

#ifndef NuvioYEnc_h
#define NuvioYEnc_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes yEnc data as it comes off the wire (CRLF lines, dots still stuffed), from the start
/// of a line, until the "\r\n=y" that starts the =yend line. `out` holds at least `length`
/// bytes. Returns the decoded length; `consumed` is how much of `data` was read and `ended` is
/// 1 when it stopped at "=y" (the =yend line starts at `data + consumed - 2`), else 0.
size_t nuvio_yenc_decode(const uint8_t *data, size_t length, uint8_t *out, size_t *consumed, int *ended);

/// 1 when the decoder uses NEON on this CPU.
int nuvio_yenc_uses_neon(void);

#ifdef __cplusplus
}
#endif

#endif /* NuvioYEnc_h */
