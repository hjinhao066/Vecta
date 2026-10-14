#ifndef VECTA_NATIVE_AUDIO_CODEC_H
#define VECTA_NATIVE_AUDIO_CODEC_H
#include <stdint.h>
#include <stddef.h>
typedef struct OPAudioCodec OPAudioCodec;
/* channels=1/2, sample rate=16000 for PLAUD fixed packets; 48000 for Ogg. */
OPAudioCodec *op_audio_create(int channels, int sample_rate, int *error);
void op_audio_destroy(OPAudioCodec *codec);
int op_audio_decode(OPAudioCodec *codec, const uint8_t *packet, int bytes,
                    int16_t *pcm, int capacity_per_channel);
int op_audio_mp3(OPAudioCodec *codec, const int16_t *pcm, int samples_per_channel,
                 uint8_t *output, int output_capacity);
int op_audio_flush(OPAudioCodec *codec, uint8_t *output, int output_capacity);
const char *op_audio_opus_version(void);
/* Vorbis is read incrementally. Negative reads fail; no skipped damaged pages. */
typedef struct OPVorbisReader OPVorbisReader;
OPVorbisReader *op_vorbis_open(const char *path, int *channels, int *rate, int64_t *frames);
int op_vorbis_read(OPVorbisReader *reader, int16_t *pcm, int capacity_per_channel);
void op_vorbis_close(OPVorbisReader *reader);
OPAudioCodec *op_audio_encoder_create(int channels, int sample_rate, int *error);
#endif
