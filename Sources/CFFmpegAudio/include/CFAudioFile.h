#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// An audio file decoded by FFmpeg into deinterleaved Float32 at its own sample rate.
/// Streams with more than two channels are downmixed to stereo.
typedef struct CFAudioFile CFAudioFile;

/// Opens the file's main audio stream. Returns NULL and fills `error` on failure.
CFAudioFile *cf_audio_open(const char *path, char *error, size_t errorSize);
/// The callback may run on the decoding thread. Its context must outlive the file.
/// Returning true interrupts open/read/seek; it is never called on the render thread.
typedef bool (*CFAudioInterrupt)(void *context);
CFAudioFile *cf_audio_open_interruptible(const char *path, CFAudioInterrupt interrupt,
                                        void *context, char *error, size_t errorSize);
void cf_audio_close(CFAudioFile *file);

/// 1 or 2.
int cf_audio_channels(const CFAudioFile *file);
double cf_audio_sample_rate(const CFAudioFile *file);
/// Length in frames from the container, or -1 when it doesn't say.
int64_t cf_audio_length(const CFAudioFile *file);

/// Decodes up to `frames` frames into `channels[0..channels-1]`. Returns the number of
/// frames written, 0 at the end of the stream, or -1 with `error` filled.
long cf_audio_read(CFAudioFile *file, float *const *channels, long frames, char *error, size_t errorSize);

/// Positions the next read at `frame`, sample-exactly. Returns false with `error` filled.
bool cf_audio_seek(CFAudioFile *file, int64_t frame, char *error, size_t errorSize);

/// A tag value, matched case-insensitively in the container's and then the stream's
/// metadata, or NULL. Valid until the file is closed.
const char *cf_audio_tag(const CFAudioFile *file, const char *key);

/// Embedded cover art, preferring a front cover, or NULL. Valid until the file is closed.
const unsigned char *cf_audio_picture(const CFAudioFile *file, size_t *size);

#ifdef __cplusplus
}
#endif
