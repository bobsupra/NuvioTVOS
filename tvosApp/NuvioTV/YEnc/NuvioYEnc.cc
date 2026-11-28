// The C entry points of NuvioYEnc.h over node-yencode's decoder (decoder.h).

#include "NuvioYEnc.h"

#include <mutex>

#include "decoder.h"

static void nuvio_yenc_init(void) {
    static std::once_flag once;
    std::call_once(once, [] { RapidYenc::decoder_init(); });
}

size_t nuvio_yenc_decode(const uint8_t *data, size_t length, uint8_t *out, size_t *consumed, int *ended) {
    nuvio_yenc_init();
    const void *src = data;
    void *dst = out;
    // Raw decoding from a line start: undoes the NNTP dot stuffing, stops at "\r\n=y".
    RapidYenc::YencDecoderState state = RapidYenc::YDEC_STATE_CRLF;
    RapidYenc::YencDecoderEnd end = RapidYenc::decode_end(&src, &dst, length, &state);
    *consumed = (size_t)((const uint8_t *)src - data);
    *ended = end == RapidYenc::YDEC_END_CONTROL ? 1 : 0;
    return (size_t)((uint8_t *)dst - out);
}

int nuvio_yenc_uses_neon(void) {
    nuvio_yenc_init();
    // ISA_LEVEL_NEON (common.h).
    return (RapidYenc::decode_isa_level() & 0x1000) != 0 ? 1 : 0;
}
