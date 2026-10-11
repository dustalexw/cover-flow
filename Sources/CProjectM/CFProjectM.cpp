#include "CFProjectM.h"
#include "projectM-4/projectM.h"
#include <dlfcn.h>
#include <string>
#include <exception>
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>

// Dynamic linking keeps the LGPL engine independently replaceable in the app.
struct CFVisualizer {
    void *library = nullptr;
    projectm_handle instance = nullptr;
    std::string error;
    decltype(&projectm_create) create;
    decltype(&projectm_destroy) destroy;
    decltype(&projectm_load_preset_file) load;
    decltype(&projectm_set_window_size) resize;
    decltype(&projectm_opengl_render_frame) render;
    decltype(&projectm_pcm_add_float) pcm;
    decltype(&projectm_pcm_get_max_samples) maxSamples;
    decltype(&projectm_set_preset_locked) lock;
    decltype(&projectm_set_soft_cut_duration) duration;
    decltype(&projectm_set_fps) fps;
    decltype(&projectm_set_mesh_size) mesh;
    decltype(&projectm_set_preset_switch_failed_event_callback) failed;
};

static void presetFailed(const char *, const char *message, void *context) {
    static_cast<CFVisualizer *>(context)->error = message ? message : "Unable to load preset.";
}

CFVisualizer *cf_visualizer_create(const char *path) {
    auto *v = new CFVisualizer;
    v->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!v->library) { v->error = "The visualizer engine is missing. Build the app with build.command."; return v; }
#define LOAD(member, symbol) \
    v->member = reinterpret_cast<decltype(v->member)>(dlsym(v->library, #symbol)); \
    if (!v->member) { v->error = "The visualizer engine has an incompatible API."; return v; }
    LOAD(create, projectm_create)
    LOAD(destroy, projectm_destroy)
    LOAD(load, projectm_load_preset_file)
    LOAD(resize, projectm_set_window_size)
    LOAD(render, projectm_opengl_render_frame)
    LOAD(pcm, projectm_pcm_add_float)
    LOAD(maxSamples, projectm_pcm_get_max_samples)
    LOAD(lock, projectm_set_preset_locked)
    LOAD(duration, projectm_set_soft_cut_duration)
    LOAD(fps, projectm_set_fps)
    LOAD(mesh, projectm_set_mesh_size)
    LOAD(failed, projectm_set_preset_switch_failed_event_callback)
#undef LOAD
    try {
        v->instance = v->create();
        if (!v->instance) { v->error = "Unable to start the visualizer on this display."; return v; }
        v->lock(v->instance, true); // The app manages preset timing and selection.
        v->duration(v->instance, 2.5);
        v->fps(v->instance, 30);
        v->mesh(v->instance, 48, 36);
        v->failed(v->instance, presetFailed, v);
    } catch (const std::exception &e) { v->error = e.what(); }
    return v;
}

void cf_visualizer_destroy(CFVisualizer *v) {
    if (!v) return;
    if (v->instance) v->destroy(v->instance);
    if (v->library) dlclose(v->library);
    delete v;
}
const char *cf_visualizer_error(CFVisualizer *v) { return v ? v->error.c_str() : "Unable to start visualizer."; }
bool cf_visualizer_load(CFVisualizer *v, const char *path, bool transition) {
    if (!v || !v->instance) return false;
    v->error.clear();
    try { v->load(v->instance, path, transition); }
    catch (const std::exception &e) { v->error = e.what(); }
    return v->error.empty();
}
void cf_visualizer_resize(CFVisualizer *v, size_t width, size_t height) {
    if (v && v->instance && width && height) v->resize(v->instance, width, height);
}
void cf_visualizer_render(CFVisualizer *v, const float *samples, unsigned frames) {
    if (!v || !v->instance) return;
    // projectM accepts a bounded window. Feed the newest samples if a frame ran late.
    const unsigned count = frames < v->maxSamples() ? frames : v->maxSamples();
    try {
        if (count) v->pcm(v->instance, samples + (frames - count) * 2, count, PROJECTM_STEREO);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        v->render(v->instance);
    } catch (const std::exception &e) { v->error = e.what(); }
}
