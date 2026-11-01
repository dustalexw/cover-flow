#pragma once
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Only call on a disposable copy. Success includes reopening and verifying the saved picture.
bool cf_artwork_write(const char *path, const unsigned char *data, size_t size,
                      const char *mime, int width, int height, char *error, size_t errorSize);

// Embedded pictures other than the front cover. kind: 1 = back cover, 2 = media (CD/vinyl label), 3 = leaflet (booklet) page.
typedef struct {
    int kind;
    unsigned char *data;
    size_t size;
} cf_picture;
// Reads up to `max` back-cover, media and leaflet pictures (each under 12 MiB) from the file's tags.
// Returns how many were stored in `out`; free them with cf_artwork_free_pictures.
size_t cf_artwork_read_extras(const char *path, cf_picture *out, size_t max);
void cf_artwork_free_pictures(cf_picture *pictures, size_t count);
#ifdef __cplusplus
}
#endif
