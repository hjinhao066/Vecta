#include "NativeAudioCodec.h"
#include <opus/opus.h>
#include <lame/lame.h>
#include <stdlib.h>
#include <vorbis/vorbisfile.h>

struct OPAudioCodec { OpusDecoder *decoder; lame_t encoder; int channels; };
OPAudioCodec *op_audio_create(int channels, int sample_rate, int *error) {
    if (error) *error = -1000;
    if ((channels != 1 && channels != 2) || (sample_rate != 16000 && sample_rate != 48000)) return NULL;
    OPAudioCodec *codec = calloc(1, sizeof(*codec));
    if (!codec) return NULL;
    codec->channels = channels;
    int decoder_error = 0;
    codec->decoder = opus_decoder_create(sample_rate, channels, &decoder_error);
    if (!codec->decoder || decoder_error) { if (error) *error = decoder_error; op_audio_destroy(codec); return NULL; }
    OPAudioCodec *encoder = op_audio_encoder_create(channels, sample_rate, error);
    if (!encoder) { op_audio_destroy(codec); return NULL; }
    codec->encoder = encoder->encoder; encoder->encoder = NULL; free(encoder);
    if (error) *error = 0;
    return codec;
}
void op_audio_destroy(OPAudioCodec *codec) {
    if (!codec) return;
    if (codec->decoder) opus_decoder_destroy(codec->decoder);
    if (codec->encoder) lame_close(codec->encoder);
    free(codec);
}
int op_audio_decode(OPAudioCodec *codec, const uint8_t *packet, int bytes, int16_t *pcm, int capacity_per_channel) {
    if (!codec || !packet || bytes <= 0 || !pcm || capacity_per_channel <= 0) return -1000;
    return opus_decode(codec->decoder, packet, bytes, pcm, capacity_per_channel, 0);
}
int op_audio_conceal(OPAudioCodec *codec, int16_t *pcm, int samples_per_channel) {
    if (!codec || !pcm || samples_per_channel != 320) return -1000;
    return opus_decode(codec->decoder, NULL, 0, pcm, samples_per_channel, 0);
}
int op_audio_mp3(OPAudioCodec *codec, const int16_t *pcm, int count, uint8_t *output, int capacity) {
    if (!codec || !pcm || count < 0 || !output) return -1000;
    if (codec->channels == 2) return lame_encode_buffer_interleaved(codec->encoder, (short *)pcm, count, output, capacity);
    return lame_encode_buffer(codec->encoder, pcm, pcm, count, output, capacity);
}
int op_audio_flush(OPAudioCodec *codec, uint8_t *output, int capacity) {
    if (!codec || !output) return -1000;
    return lame_encode_flush(codec->encoder, output, capacity);
}
const char *op_audio_opus_version(void) { return opus_get_version_string(); }

OPAudioCodec *op_audio_encoder_create(int channels, int sample_rate, int *error) {
    if (error) *error = -1000;
    if ((channels != 1 && channels != 2) || sample_rate < 8000 || sample_rate > 192000) return NULL;
    OPAudioCodec *codec = calloc(1, sizeof(*codec));
    if (!codec) return NULL;
    codec->channels = channels;
    codec->encoder = lame_init();
    if (!codec->encoder || lame_set_num_channels(codec->encoder, channels) ||
        lame_set_in_samplerate(codec->encoder, sample_rate) || lame_set_brate(codec->encoder, 128) ||
        lame_set_quality(codec->encoder, 3) || lame_init_params(codec->encoder) < 0) {
        if (error) *error = -1001; op_audio_destroy(codec); return NULL;
    }
    if (error) *error = 0;
    return codec;
}
struct OPVorbisReader { OggVorbis_File file; int channels; };
OPVorbisReader *op_vorbis_open(const char *path, int *channels, int *rate, int64_t *frames) {
    OPVorbisReader *reader = calloc(1, sizeof(*reader));
    if (!reader) return NULL;
    if (ov_fopen(path, &reader->file) < 0) { free(reader); return NULL; }
    vorbis_info *info = ov_info(&reader->file, -1);
    ogg_int64_t total = ov_pcm_total(&reader->file, -1);
    if (!info || ov_streams(&reader->file) != 1 || total <= 0 ||
        (info->channels != 1 && info->channels != 2) || info->rate < 8000 || info->rate > 192000) {
        op_vorbis_close(reader); return NULL;
    }
    reader->channels = info->channels; *channels = info->channels; *rate = (int)info->rate; *frames = total;
    return reader;
}
int op_vorbis_read(OPVorbisReader *reader, int16_t *pcm, int capacity_per_channel) {
    if (!reader || !pcm || capacity_per_channel <= 0 || capacity_per_channel > 192000) return -1000;
    int section = 0;
    long bytes = ov_read(&reader->file, (char *)pcm, capacity_per_channel * reader->channels * 2, 0, 2, 1, &section);
    if (bytes < 0 || section != 0 || bytes % (reader->channels * 2)) return -1000;
    return (int)(bytes / (reader->channels * 2));
}
void op_vorbis_close(OPVorbisReader *reader) {
    if (!reader) return;
    ov_clear(&reader->file); free(reader);
}
