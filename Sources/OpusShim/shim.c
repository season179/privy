#include "include/opus_shim.h"

int opus_shim_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

int opus_shim_set_signal_voice(OpusEncoder *enc) {
    return opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int opus_shim_get_lookahead(OpusEncoder *enc, opus_int32 *lookahead) {
    return opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(lookahead));
}
