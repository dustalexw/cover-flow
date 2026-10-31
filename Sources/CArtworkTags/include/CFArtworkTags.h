#pragma once
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Only call on a disposable copy. Success includes reopening and verifying the saved picture.
bool cf_artwork_write(const char *path, const unsigned char *data, size_t size,
                      const char *mime, int width, int height, char *error, size_t errorSize);
// Sets text tags on a disposable copy. keys are TagLib property names (TITLE, ARTIST,
// ALBUM, ALBUMARTIST, DATE, GENRE, TRACKNUMBER, DISCNUMBER); an empty value removes the
// tag. Values the file already has are left alone (a matching leading number counts for
// TRACKNUMBER/DISCNUMBER, a matching year for DATE), and "3/12" keeps its "/12". Other
// tags and pictures are kept. *changed says whether the file was rewritten; success
// includes reopening and verifying the values.
bool cf_tags_write(const char *path, const char *const *keys, const char *const *values, size_t count,
                   bool *changed, char *error, size_t errorSize);
#ifdef __cplusplus
}
#endif
