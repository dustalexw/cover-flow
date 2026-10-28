#include "CFAudioFile.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/avstring.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

/// Returned while seeking when a decoded frame carries no timestamp.
#define CF_NO_TIMESTAMP FFERRTAG('C', 'F', 'N', 'T')

/// Frame positions count decoded output from the first frame the decoder returns, the
/// way a plain decode of the file plays. Timestamps place frames after a seek; `origin`
/// is the first frame's timestamp, so both agree even where a codec's timestamps start
/// above zero (Vorbis after its first packet, WMA after its delay).
struct CFAudioFile {
    char *path;
    CFAudioInterrupt interrupt;
    void *interruptContext;
    AVFormatContext *format;
    AVCodecContext *codec;
    AVStream *stream;
    int streamIndex;
    AVPacket *packet;
    AVFrame *frame;

    SwrContext *resampler;
    AVChannelLayout resamplerLayout;
    int resamplerFormat;
    int resamplerRate;

    /// Converted samples waiting to be read; `position` is the frame index of the first.
    AVAudioFifo *fifo;
    uint8_t **conversionBuffer;
    int conversionCapacity;
    bool packetPending;
    bool drainSent;
    int64_t position;
    /// Decoded samples before this frame are dropped (after a seek).
    int64_t discardUntil;
    /// The next frame's timestamp sets `position` (after a seek), or `origin` (at open).
    bool needsPosition;
    bool findingOrigin;
    int64_t origin;
    int64_t landing;

    int channels;
    int rate;
    int64_t length;
    bool readMetadata;
    bool scannedDuration;
    bool packetsDone;
    bool decoderDone;
};

static pthread_once_t loggingOnce = PTHREAD_ONCE_INIT;
static void configureLogging(void) { av_log_set_level(AV_LOG_ERROR); }

static void fail(char *error, size_t size, const char *message, int code) {
    if (!error || !size) return;
    if (code < 0 && code != CF_NO_TIMESTAMP) {
        char reason[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(code, reason, sizeof reason);
        snprintf(error, size, "%s (%s).", message, reason);
    } else {
        snprintf(error, size, "%s.", message);
    }
}

static void closeStream(CFAudioFile *file) {
    avcodec_free_context(&file->codec);
    avformat_close_input(&file->format);
    file->stream = NULL;
    file->streamIndex = -1;
}

void cf_audio_close(CFAudioFile *file) {
    if (!file) return;
    swr_free(&file->resampler);
    av_channel_layout_uninit(&file->resamplerLayout);
    if (file->fifo) av_audio_fifo_free(file->fifo);
    if (file->conversionBuffer) av_freep(&file->conversionBuffer[0]);
    av_freep(&file->conversionBuffer);
    av_packet_free(&file->packet);
    av_frame_free(&file->frame);
    closeStream(file);
    av_free(file->path);
    av_free(file);
}

static bool interrupted(const CFAudioFile *file) {
    return file->interrupt && file->interrupt(file->interruptContext);
}

static int interruptIO(void *context) { return interrupted(context); }

/// Opens the container and the decoder for its main audio stream.
static bool openStream(CFAudioFile *file, char *error, size_t errorSize) {
    if (interrupted(file)) { fail(error, errorSize, "Audio decoding cancelled", AVERROR_EXIT); return false; }
    file->format = avformat_alloc_context();
    if (!file->format) { fail(error, errorSize, "Out of memory", AVERROR(ENOMEM)); return false; }
    file->format->interrupt_callback = (AVIOInterruptCB){interruptIO, file};
    int result = avformat_open_input(&file->format, file->path, NULL, NULL);
    if (result < 0) {
        fail(error, errorSize, "The file couldn’t be opened as audio", result);
        return false;
    }
    if ((result = avformat_find_stream_info(file->format, NULL)) < 0) {
        fail(error, errorSize, "The audio stream couldn’t be read", result);
        return false;
    }
    const AVCodec *decoder = NULL;
    result = av_find_best_stream(file->format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    if (result == AVERROR_DECODER_NOT_FOUND) {
        fail(error, errorSize, "This file’s audio codec isn’t supported", 0);
        return false;
    }
    if (result < 0 || !decoder) {
        fail(error, errorSize, "The file contains no audio", 0);
        return false;
    }
    file->streamIndex = result;
    file->stream = file->format->streams[result];
    // Cover art is read with the headers; other streams' packets are not needed.
    for (unsigned i = 0; i < file->format->nb_streams; i++) {
        if ((int)i != file->streamIndex) file->format->streams[i]->discard = AVDISCARD_ALL;
    }
    if (!(file->codec = avcodec_alloc_context3(decoder))) {
        fail(error, errorSize, "Out of memory", 0);
        return false;
    }
    if ((result = avcodec_parameters_to_context(file->codec, file->stream->codecpar)) < 0) {
        fail(error, errorSize, "The audio stream couldn’t be read", result);
        return false;
    }
    // Keep decoder workers bounded when several stems or rapid seeks overlap.
    file->codec->thread_count = 2;
    file->codec->pkt_timebase = file->stream->time_base;
    if ((result = avcodec_open2(file->codec, decoder, NULL)) < 0) {
        fail(error, errorSize, "The audio decoder couldn’t start", result);
        return false;
    }
    if (!file->readMetadata) {
        // Codec extradata and side data stay intact. Only display tags/pictures
        // are released; the metadata worker reads those using a separate handle.
        av_dict_free(&file->format->metadata);
        for (unsigned i = 0; i < file->format->nb_streams; i++) {
            AVStream *stream = file->format->streams[i];
            av_packet_unref(&stream->attached_pic);
            av_dict_free(&stream->metadata);
        }
    }
    return true;
}

static void resetDecoding(CFAudioFile *file) {
    av_audio_fifo_reset(file->fifo);
    swr_free(&file->resampler);
    av_channel_layout_uninit(&file->resamplerLayout);
    av_packet_unref(file->packet);
    av_frame_unref(file->frame);
    file->packetPending = false;
    file->drainSent = false;
    file->packetsDone = false;
    file->decoderDone = false;
}

/// Reopens the file at its start, for formats that can't seek by timestamp.
static bool restart(CFAudioFile *file, char *error, size_t errorSize) {
    closeStream(file);
    if (!openStream(file, error, errorSize)) return false;
    resetDecoding(file);
    file->needsPosition = false;
    file->position = 0;
    file->discardUntil = 0;
    return true;
}

/// Converts any sample format, rate and layout to Float32 planar at the stream's opening
/// rate, downmixing more than two channels to stereo.
static int prepareResampler(CFAudioFile *file, const AVFrame *frame) {
    int rate = frame->sample_rate > 0 ? frame->sample_rate : file->rate;
    if (file->resampler && file->resamplerFormat == frame->format && file->resamplerRate == rate &&
        av_channel_layout_compare(&file->resamplerLayout, &frame->ch_layout) == 0) {
        return 0;
    }
    swr_free(&file->resampler);
    av_channel_layout_uninit(&file->resamplerLayout);
    int result = av_channel_layout_copy(&file->resamplerLayout, &frame->ch_layout);
    if (result < 0) return result;
    AVChannelLayout input = {0};
    if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
        av_channel_layout_default(&input, frame->ch_layout.nb_channels);
    } else if ((result = av_channel_layout_copy(&input, &frame->ch_layout)) < 0) {
        return result;
    }
    AVChannelLayout output = {0};
    av_channel_layout_default(&output, file->channels);
    result = swr_alloc_set_opts2(&file->resampler, &output, AV_SAMPLE_FMT_FLTP, file->rate,
                                 &input, frame->format, rate, 0, NULL);
    av_channel_layout_uninit(&input);
    av_channel_layout_uninit(&output);
    if (result < 0) return result;
    // Keep downmixed surround from clipping.
    av_opt_set_double(file->resampler, "rematrix_maxval", 1.0, 0);
    if ((result = swr_init(file->resampler)) < 0) return result;
    file->resamplerFormat = frame->format;
    file->resamplerRate = rate;
    return 0;
}

static int convert(CFAudioFile *file, const uint8_t **input, int count) {
    int capacity = swr_get_out_samples(file->resampler, count);
    if (capacity <= 0) return capacity < 0 ? capacity : 0;
    if (capacity > file->conversionCapacity) {
        uint8_t **buffer = NULL;
        int result = av_samples_alloc_array_and_samples(&buffer, NULL, file->channels,
                                                       capacity, AV_SAMPLE_FMT_FLTP, 0);
        if (result < 0) return result;
        if (file->conversionBuffer) av_freep(&file->conversionBuffer[0]);
        av_freep(&file->conversionBuffer);
        file->conversionBuffer = buffer;
        file->conversionCapacity = capacity;
    }
    int converted = swr_convert(file->resampler, file->conversionBuffer, capacity, input, count);
    if (converted <= 0) return converted < 0 ? converted : 0;
    int written = av_audio_fifo_write(file->fifo, (void **)file->conversionBuffer, converted);
    return written == converted ? 0 : written < 0 ? written : AVERROR(ENOMEM);
}

static void discard(CFAudioFile *file) {
    if (file->position >= file->discardUntil) return;
    int64_t excess = file->discardUntil - file->position;
    int available = av_audio_fifo_size(file->fifo);
    int drop = excess < available ? (int)excess : available;
    av_audio_fifo_drain(file->fifo, drop);
    file->position += drop;
}

static int acceptFrame(CFAudioFile *file, AVFrame *frame) {
    if (frame->nb_samples <= 0) return 0;
    if (file->needsPosition) {
        int64_t timestamp = frame->best_effort_timestamp;
        if (timestamp == AV_NOPTS_VALUE) timestamp = frame->pts;
        int64_t raw = 0;
        if (timestamp != AV_NOPTS_VALUE) {
            int64_t start = file->stream->start_time != AV_NOPTS_VALUE ? file->stream->start_time : 0;
            raw = av_rescale_q(timestamp - start, file->stream->time_base, (AVRational){1, file->rate});
        } else if (!file->findingOrigin) {
            return CF_NO_TIMESTAMP;
        }
        if (file->findingOrigin) {
            file->origin = raw;
            file->findingOrigin = false;
        }
        file->position = raw - file->origin;
        file->landing = file->position;
        file->needsPosition = false;
    }
    int result = prepareResampler(file, frame);
    if (result < 0) return result;
    if ((result = convert(file, (const uint8_t **)frame->extended_data, frame->nb_samples)) < 0) return result;
    discard(file);
    return 0;
}

/// Decodes one more frame into the FIFO. Returns 0, AVERROR_EOF at the end, or an error.
static int decodeMore(CFAudioFile *file) {
    for (int damaged = 0;;) {
        if (interrupted(file)) return AVERROR_EXIT;
        int result = avcodec_receive_frame(file->codec, file->frame);
        if (result == 0) {
            result = acceptFrame(file, file->frame);
            av_frame_unref(file->frame);
            return result;
        }
        if (result == AVERROR_EOF) {
            // A resampler delays a few samples; collect them at the end.
            if (file->resampler && !file->needsPosition) {
                if ((result = convert(file, NULL, 0)) < 0) return result;
                discard(file);
            }
            return AVERROR_EOF;
        }
        // A frame that fails to decode is skipped rather than ending playback.
        if (result == AVERROR_INVALIDDATA && ++damaged < 1000) continue;
        if (result != AVERROR(EAGAIN)) return result;
        if (file->packetPending) {
            result = avcodec_send_packet(file->codec, file->packet);
            // Both send and receive returning EAGAIN violates FFmpeg's contract.
            // Keep the packet owned until success or close; never silently drop it.
            if (result == AVERROR(EAGAIN)) return AVERROR_BUG;
            av_packet_unref(file->packet);
            file->packetPending = false;
            if (result < 0 && result != AVERROR_INVALIDDATA) return result;
            if (result == AVERROR_INVALIDDATA && ++damaged >= 1000) return result;
            continue;
        }
        if (file->packetsDone) {
            if (file->drainSent) return AVERROR_BUG;
            result = avcodec_send_packet(file->codec, NULL);
            if (result < 0 && result != AVERROR_EOF) return result;
            file->drainSent = true;
            continue;
        }
        result = av_read_frame(file->format, file->packet);
        if (result < 0) {
            av_packet_unref(file->packet);
            if (result == AVERROR_INVALIDDATA && ++damaged < 1000) continue;
            if (result != AVERROR_EOF) return result;
            file->packetsDone = true;
            continue;
        }
        if (file->packet->stream_index == file->streamIndex) file->packetPending = true;
        else av_packet_unref(file->packet);
    }
}

/// Decodes the first frame, which sets `origin`. Returns 0, AVERROR_EOF or an error.
static int prime(CFAudioFile *file) {
    file->needsPosition = true;
    file->findingOrigin = true;
    file->position = 0;
    file->discardUntil = 0;
    int result;
    do {
        result = decodeMore(file);
    } while (result == 0 && file->needsPosition);
    if (result == AVERROR_EOF) file->decoderDone = true;
    file->needsPosition = false;
    file->findingOrigin = false;
    return result;
}

CFAudioFile *cf_audio_open(const char *path, char *error, size_t errorSize) {
    return cf_audio_open_interruptible(path, NULL, NULL, error, errorSize);
}

CFAudioFile *cf_audio_open_interruptible(const char *path, CFAudioInterrupt interrupt,
                                        void *context, char *error, size_t errorSize) {
    return cf_audio_open_cached(path, -1, 0, true, interrupt, context, error, errorSize);
}

CFAudioFile *cf_audio_open_cached(const char *path, int64_t cachedFrames, int cachedRate,
                                bool readMetadata, CFAudioInterrupt interrupt, void *context,
                                char *error, size_t errorSize) {
    // FFmpeg's warnings about unusual but readable files would only fill the console.
    pthread_once(&loggingOnce, configureLogging);
    if (!path || !path[0]) { fail(error, errorSize, "Missing audio filename", AVERROR(EINVAL)); return NULL; }
    CFAudioFile *file = av_mallocz(sizeof *file);
    if (!file || !(file->path = av_strdup(path))) {
        av_free(file);
        fail(error, errorSize, "Out of memory", 0);
        return NULL;
    }
    file->readMetadata = readMetadata;
    file->interrupt = interrupt;
    file->interruptContext = context;
    file->streamIndex = -1;
    file->length = -1;
    if (!openStream(file, error, errorSize)) goto failed;
    // Some decoders (DSD) set their output rate when they open.
    int channels = file->codec->ch_layout.nb_channels;
    if (channels <= 0) channels = file->stream->codecpar->ch_layout.nb_channels;
    file->rate = file->codec->sample_rate > 0 ? file->codec->sample_rate : file->stream->codecpar->sample_rate;
    if (channels <= 0 || file->rate <= 0) {
        fail(error, errorSize, "The audio stream has no channels or sample rate", 0);
        goto failed;
    }
    file->channels = channels >= 2 ? 2 : 1;

    AVRational frames = {1, file->rate};
    if (file->stream->duration != AV_NOPTS_VALUE && file->stream->duration > 0) {
        file->length = av_rescale_q(file->stream->duration, file->stream->time_base, frames);
    } else if (file->format->duration != AV_NOPTS_VALUE && file->format->duration > 0) {
        file->length = av_rescale_q(file->format->duration, AV_TIME_BASE_Q, frames);
    }

    file->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, file->channels, 8192);
    file->packet = av_packet_alloc();
    file->frame = av_frame_alloc();
    if (!file->fifo || !file->packet || !file->frame) {
        fail(error, errorSize, "Out of memory", 0);
        goto failed;
    }
    int result = prime(file);
    if (result < 0 && result != AVERROR_EOF) {
        fail(error, errorSize, "The audio couldn’t be decoded", result);
        goto failed;
    }
    if (file->length < 0 && cachedFrames > 0 && cachedRate == file->rate) file->length = cachedFrames;
    if (file->length < 0) {
        file->scannedDuration = true;
        // Some containers (Musepack) record no duration: count the decoded samples.
        int64_t count = 0;
        do {
            int available = av_audio_fifo_size(file->fifo);
            av_audio_fifo_drain(file->fifo, available);
            count += available;
        } while (!file->decoderDone && (result = decodeMore(file)) == 0);
        if (result < 0 && result != AVERROR_EOF) {
            fail(error, errorSize, "The audio couldn’t be decoded", result);
            goto failed;
        }
        count += av_audio_fifo_size(file->fifo);
        file->length = count;
        if (!restart(file, error, errorSize)) goto failed;
    }
    return file;

failed:
    cf_audio_close(file);
    return NULL;
}

bool cf_audio_scanned_duration(const CFAudioFile *file) { return file->scannedDuration; }

int cf_audio_channels(const CFAudioFile *file) { return file->channels; }
double cf_audio_sample_rate(const CFAudioFile *file) { return file->rate; }
int64_t cf_audio_length(const CFAudioFile *file) { return file->length; }

long cf_audio_read(CFAudioFile *file, float *const *channels, long frames, char *error, size_t errorSize) {
    if (!file || !file->codec || frames > INT_MAX || frames < 0 || !channels) {
        fail(error, errorSize, "Invalid audio read", AVERROR(EINVAL)); return -1;
    }
    for (int c = 0; c < file->channels; c++) {
        if (!channels[c]) { fail(error, errorSize, "Missing audio channel", AVERROR(EINVAL)); return -1; }
    }
    if (interrupted(file)) { fail(error, errorSize, "Audio decoding cancelled", AVERROR_EXIT); return -1; }
    if (frames == 0) return 0;
    while (av_audio_fifo_size(file->fifo) < frames && !file->decoderDone) {
        int result = decodeMore(file);
        if (result == AVERROR_EOF) {
            file->decoderDone = true;
        } else if (result < 0) {
            fail(error, errorSize, "The audio couldn’t be decoded", result);
            return -1;
        }
    }
    int available = av_audio_fifo_size(file->fifo);
    int count = frames < available ? (int)frames : available;
    if (count <= 0) return 0;
    int read = av_audio_fifo_read(file->fifo, (void *const *)channels, count);
    if (read < 0) {
        fail(error, errorSize, "The audio couldn’t be decoded", read);
        return -1;
    }
    file->position += read;
    return read;
}

bool cf_audio_seek(CFAudioFile *file, int64_t frame, char *error, size_t errorSize) {
    if (!file || !file->stream || interrupted(file)) {
        fail(error, errorSize, "Audio decoding cancelled or unavailable", AVERROR_EXIT); return false;
    }
    if (frame < 0) frame = 0;
    if (file->length >= 0 && frame > file->length) frame = file->length;
    int64_t start = file->stream->start_time != AV_NOPTS_VALUE ? file->stream->start_time : 0;
    AVRational frames = {1, file->rate};
    // Container indexes can land after the requested time; back off further until the
    // first decoded frame starts early enough, then drop the samples in between. Codecs
    // that need to converge after a jump (Opus) ask for a pre-roll.
    int64_t preroll = file->stream->codecpar->seek_preroll > 0 ? file->stream->codecpar->seek_preroll : 0;
    int64_t backoff = preroll;
    for (int attempt = 0; frame > 0 && attempt < 10; attempt++) {
        int64_t target = frame > backoff ? frame - backoff : 0;
        int64_t timestamp = start + av_rescale_q(target + file->origin, frames, file->stream->time_base);
        int result = av_seek_frame(file->format, file->streamIndex, timestamp, AVSEEK_FLAG_BACKWARD);
        if (result < 0) result = avformat_seek_file(file->format, file->streamIndex, INT64_MIN, timestamp, timestamp, 0);
        if (result < 0) break;
        avcodec_flush_buffers(file->codec);
        resetDecoding(file);
        file->needsPosition = true;
        file->discardUntil = frame;
        file->position = frame;
        do {
            result = decodeMore(file);
        } while (result == 0 && file->needsPosition);
        if (result == CF_NO_TIMESTAMP) break;
        if (result < 0 && result != AVERROR_EOF) {
            fail(error, errorSize, "The audio couldn’t be positioned", result);
            return false;
        }
        if (result == AVERROR_EOF) file->decoderDone = true;
        if (file->needsPosition) {
            // Nothing decoded after the jump: either the request is past the end, or
            // the container jumped too far and an earlier point is needed.
            file->needsPosition = false;
            if (file->length >= 0 && frame >= file->length) return true;
            if (target == 0) break;
            backoff = backoff > preroll ? backoff * 2 : preroll + file->rate;
            continue;
        }
        if (file->landing <= frame - preroll || (target == 0 && file->landing <= frame)) return true;
        if (target == 0) break;
        backoff = backoff > preroll ? backoff * 2 : preroll + file->rate;
    }
    // Decode from the start and drop everything before the frame.
    if (!restart(file, error, errorSize)) return false;
    file->discardUntil = frame;
    return true;
}

const char *cf_audio_tag(const CFAudioFile *file, const char *key) {
    AVDictionaryEntry *entry = av_dict_get(file->format->metadata, key, NULL, 0);
    if (!entry || !entry->value[0]) entry = av_dict_get(file->stream->metadata, key, NULL, 0);
    return entry && entry->value[0] ? entry->value : NULL;
}

static bool looksLikeImage(const uint8_t *data, int size) {
    if (size < 4) return false;
    return (data[0] == 0xFF && data[1] == 0xD8) ||                               // JPEG
           (data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G') || // PNG
           (data[0] == 'G' && data[1] == 'I' && data[2] == 'F') ||                 // GIF
           (data[0] == 'B' && data[1] == 'M') ||                                   // BMP
           (size >= 12 && !memcmp(data, "RIFF", 4) && !memcmp(data + 8, "WEBP", 4));
}

/// An APE tag cover ("Cover Art (Front)") that FFmpeg left as a plain attachment because
/// its stored file name has no image extension, as TagLib and some taggers write it.
static bool apeCover(const AVStream *stream, bool *front) {
    if (stream->codecpar->codec_type != AVMEDIA_TYPE_ATTACHMENT ||
        !looksLikeImage(stream->codecpar->extradata, stream->codecpar->extradata_size)) {
        return false;
    }
    const AVDictionaryEntry *entry = NULL;
    while ((entry = av_dict_iterate(stream->metadata, entry))) {
        if (av_strncasecmp(entry->key, "Cover Art", 9) == 0) {
            *front = av_stristr(entry->key, "front") != NULL;
            return true;
        }
    }
    return false;
}

const unsigned char *cf_audio_picture(const CFAudioFile *file, size_t *size) {
    const uint8_t *best = NULL;
    int bestSize = 0;
    bool bestIsFront = false;
    for (unsigned i = 0; i < file->format->nb_streams && !bestIsFront; i++) {
        const AVStream *stream = file->format->streams[i];
        const uint8_t *data;
        int length;
        bool front = false;
        if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) && stream->attached_pic.size > 0) {
            data = stream->attached_pic.data;
            length = stream->attached_pic.size;
            // ID3, FLAC and Ogg pictures name their type in "comment"; APE tags use the item key.
            const AVDictionaryEntry *type = av_dict_get(stream->metadata, "comment", NULL, 0);
            front = (type && av_stristr(type->value, "front")) ||
                    av_dict_get(stream->metadata, "Cover Art (Front)", NULL, 0);
        } else if (apeCover(stream, &front)) {
            data = stream->codecpar->extradata;
            length = stream->codecpar->extradata_size;
        } else {
            continue;
        }
        if (!best || front) {
            best = data;
            bestSize = length;
            bestIsFront = front;
        }
    }
    if (!best) return NULL;
    *size = (size_t)bestSize;
    return best;
}
