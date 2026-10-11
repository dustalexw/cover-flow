#pragma once
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CFVisualizer CFVisualizer;
// All calls require the view's OpenGL context current, on its render thread.
CFVisualizer *cf_visualizer_create(const char *library_path);
void cf_visualizer_destroy(CFVisualizer *visualizer);
const char *cf_visualizer_error(CFVisualizer *visualizer);
bool cf_visualizer_load(CFVisualizer *visualizer, const char *preset, bool transition);
void cf_visualizer_resize(CFVisualizer *visualizer, size_t width, size_t height);
void cf_visualizer_render(CFVisualizer *visualizer, const float *samples, unsigned frames);
#ifdef __cplusplus
}
#endif
