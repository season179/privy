#ifndef OPUS_SHIM_H
#define OPUS_SHIM_H

#include <opus.h>

// opus_encoder_ctl is variadic and macro-driven, which Swift cannot call.
// These wrappers expose the ctls Privy needs.

int opus_shim_set_bitrate(OpusEncoder *enc, opus_int32 bitrate);
int opus_shim_set_signal_voice(OpusEncoder *enc);
int opus_shim_get_lookahead(OpusEncoder *enc, opus_int32 *lookahead);

#endif
