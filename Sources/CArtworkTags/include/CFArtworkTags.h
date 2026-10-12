#pragma once
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Only call on a disposable copy. Success includes reopening and verifying the saved picture.
bool cf_artwork_write(const char *path, const unsigned char *data, size_t size,
                      const char *mime, int width, int height, char *error, size_t errorSize);
#ifdef __cplusplus
}
#endif
