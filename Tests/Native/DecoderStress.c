#include "CFAudioFile.h"
#include <assert.h>
#include <math.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static bool cancelled(void *context) { return atomic_load((_Atomic bool *)context); }

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *fixtures[] = {"tone.wv", "tone.tta", "tone.mka", "tone.ogg", "tone.wma", "tone.spx", "tone.mpc", "tone.dsf"};
    float left[4096], right[4096];
    float *channels[] = {left, right};
    char error[512], path[4096];
    int iterations = 0;
    for (int repeat = 0; repeat < 150; repeat++) {
        for (unsigned i = 0; i < sizeof fixtures / sizeof *fixtures; i++) {
            snprintf(path, sizeof path, "%s/%s", argv[1], fixtures[i]);
            _Atomic bool interrupt = false;
            CFAudioFile *file = cf_audio_open_interruptible(path, cancelled, &interrupt, error, sizeof error);
            if (!file) { fprintf(stderr, "%s: %s\n", path, error); return 1; }
            int64_t length = cf_audio_length(file);
            assert(length > 0 && cf_audio_channels(file) > 0 && cf_audio_channels(file) <= 2);
            for (int seek = 0; seek < 4; seek++) {
                assert(cf_audio_seek(file, length * seek / 5, error, sizeof error));
                long count = cf_audio_read(file, channels, 4096, error, sizeof error);
                assert(count >= 0 && count <= 4096);
                for (long frame = 0; frame < count; frame++) assert(isfinite(left[frame]));
            }
            assert(cf_audio_seek(file, INT64_MAX, error, sizeof error));
            assert(cf_audio_read(file, channels, LONG_MAX, error, sizeof error) == -1);
            atomic_store(&interrupt, true);
            assert(cf_audio_read(file, channels, 4096, error, sizeof error) == -1);
            assert(!cf_audio_seek(file, 0, error, sizeof error));
            cf_audio_close(file);
            assert(!cf_audio_open_interruptible(path, cancelled, &interrupt, error, sizeof error));
            iterations++;
        }
    }
    char damaged[] = "/tmp/cover-flow-corrupt-XXXXXX";
    int descriptor = mkstemp(damaged);
    assert(descriptor >= 0);
    const unsigned char header[] = {'O','g','g','S',0,2,0,0,0,0,0,0,0,0};
    assert(write(descriptor, header, sizeof header) == sizeof header);
    close(descriptor);
    for (int i = 0; i < 100; i++) {
        CFAudioFile *file = cf_audio_open(damaged, error, sizeof error);
        cf_audio_close(file);
        assert(!cf_audio_open("/no/such/cover-flow-audio", error, sizeof error));
        assert(!cf_audio_open(NULL, error, sizeof error));
    }
    unlink(damaged);
    printf("Passed %d decoder lifecycles, 6000 seeks, cancellation, and malformed-input cleanup.\n", iterations);
    return 0;
}
