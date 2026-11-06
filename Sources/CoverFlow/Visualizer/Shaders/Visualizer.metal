#include <metal_stdlib>
using namespace metal;

// size, time, style, audio = (bass, mid, treble, level), onset, motion (0 with Reduce
// Motion), beat (1 on a beat, decaying), flux (how fast the spectrum changes), drive (a
// clock that runs faster with louder, busier music), hue (steps on every beat) and
// swell (the beat eased in and out, for styles that should breathe rather than jump).
struct Uniforms {
    float2 size; float time; float style; float4 audio;
    float onset; float motion; float beat; float flux; float drive; float hue; float swell; float spare;
};
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut visualizerVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2 - 1, 0, 1), p};
}

constant float TAU = 6.2831853f;

float hash21(float2 p) { return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f); }
float noise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3 - 2 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x), mix(hash21(i + float2(0, 1)), hash21(i + 1), f.x), f.y);
}
float fbm(float2 p) {
    float value = 0, weight = 0.5f;
    for (int j = 0; j < 5; j++) { value += weight * noise(p); p = p * 2.03f + float2(5.2f, 1.3f); weight *= 0.5f; }
    return value;
}
float2x2 rotation(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, s), float2(-s, c)); }
float band(constant float *bands, float value) {
    float i = clamp(value, 0.0f, 1.0f) * 63;
    uint low = uint(i); return mix(bands[low], bands[min(63u, low + 1)], fract(i));
}
float wave(constant float *waves, float value) {
    float i = clamp(value, 0.0f, 1.0f) * 511;
    uint low = uint(i); return mix(waves[low], waves[min(511u, low + 1)], fract(i));
}
float circularWave(constant float *waves, float a) {
    // Fade the waveform into the wrap point so circular styles have no radial seam.
    float seam = smoothstep(0.0f, 0.08f, min(a, 1 - a));
    return wave(waves, a) * seam;
}
float3 palette(float x) { return 0.55f + 0.45f * cos(TAU * (float3(0.05f, 0.33f, 0.58f) + x)); }
// A hotter, more saturated palette for the psychedelic styles.
float3 acid(float x) { return 0.5f + 0.5f * cos(TAU * (float3(0.0f, 0.1f, 0.2f) + x * float3(1.0f, 0.7f, 0.4f))); }
float glow(float distance, float width) { return exp(-abs(distance) / max(0.0001f, width)); }
// A crisp, anti-aliased line core: full strength within `radius` of the curve, fading
// to nothing over about one device pixel, so edges stay sharp at any resolution.
float core(float distance, float radius, float px) { return 1 - smoothstep(radius, radius + px * 1.25f, abs(distance)); }

fragment float4 visualizerFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                   constant float *bands [[buffer(1)]], constant float *waves [[buffer(2)]]) {
    float2 uv = in.uv;
    float aspect = u.size.x / u.size.y;
    float2 p = (uv - 0.5f) * float2(aspect, 1);
    float t = u.time * u.motion;
    float d = u.drive * u.motion;                  // music-driven clock
    float kick = u.beat * u.motion;                 // beat punch (still with Reduce Motion)
    float r = length(p), angle = atan2(p.y, p.x);
    float bass = u.audio.x, mid = u.audio.y, treble = u.audio.z, level = u.audio.w;
    float px = 1.0f / u.size.y;                     // one device pixel in p units
    int style = int(u.style + 0.5f);
    float haze = noise(p * 2.2f + float2(t * 0.025f, 0));
    float3 color = float3(0.003f, 0.006f, 0.016f) + float3(0.008f, 0.012f, 0.032f) * haze;
    // Fine, stable stars: energy changes their radiance, never a full-screen flash.
    if (style != 6 && style != 7) {
        float2 cell = p * 85, grid = floor(cell);
        float star = step(0.991f, hash21(grid)) * exp(-length(fract(cell) - 0.5f) * 19);
        color += palette(hash21(grid + 10)) * star * (0.12f + treble * 0.3f + kick * 0.2f);
    }

    if (style == 0) {                               // Pulse
        float a = fract(angle / TAU + 0.5f);
        float power = band(bands, abs(a * 2 - 1));
        float radius = 0.23f + bass * 0.05f + kick * 0.045f;
        float dist = r - radius - power * (0.14f + kick * 0.06f);
        color += palette(a + d * 0.03f + u.hue) * (glow(dist, 0.011f + kick * 0.01f) * (0.3f + power * 1.3f) + core(dist, px * 0.6f, px) * 1.6f);
        float inner = r - radius * 0.86f - circularWave(waves, a) * (0.03f + mid * 0.03f);
        color += float3(0.35f, 0.8f, 1) * (glow(inner, 0.003f) * 0.6f + core(inner, px * 0.4f, px)) * (0.15f + mid * 0.9f);
        // A shockwave ring races outward on every beat.
        float shock = r - (radius + (1 - u.beat) * 0.55f);
        color += palette(u.hue + 0.5f) * glow(shock, 0.006f + (1 - u.beat) * 0.02f) * u.beat * 0.9f;
        for (int j = 0; j < 3; j++) {
            float orbit = radius + 0.05f + float(j) * 0.025f + sin(angle * 3 + d * 0.6f + float(j)) * (0.009f + 0.02f * mid);
            color += palette(a + float(j) * 0.16f + u.hue) * core(r - orbit, px * 0.3f, px) * (0.05f + treble * 0.2f);
        }
    } else if (style == 1) {                        // Aurora
        // Curtains of light: each ribbon has a sharp, bright lower edge and rays that
        // fade upward. Everything moves on smooth noise and eased audio (no raw
        // waveform, no instant beat jumps), so it flows instead of shaking.
        float swell = u.swell * u.motion;
        color = mix(float3(0.004f, 0.002f, 0.02f), float3(0.0f, 0.012f, 0.03f), uv.y) + color * 0.6f;
        for (int j = 0; j < 4; j++) {
            float f = float(j);
            float x = p.x;
            float drift = d * (0.05f + f * 0.012f);
            float flow = fbm(float2(x * 0.8f + f * 3.1f + drift, drift * 0.7f + f * 1.7f));
            float sway = sin(x * (1.1f + f * 0.23f) + d * (0.16f + f * 0.03f) + f * 1.9f);
            float y0 = -0.16f + f * 0.075f + (flow - 0.5f) * (0.42f + bass * 0.22f + swell * 0.12f) + sway * (0.05f + mid * 0.04f);
            float dy = p.y - y0;
            // Long fade upward, a soft edge below.
            float curtain = dy >= 0 ? exp(-dy * (4.2f - mid * 1.6f - swell)) : exp(dy * 38);
            // Rays: fine vertical striations that slide sideways.
            float rays = 0.45f + 0.55f * fbm(float2(x * 16 + f * 7 + drift * 6, d * 0.12f + f));
            rays *= 0.75f + 0.25f * sin(x * 60 + d * 0.8f + f * 4);
            // Each part of the curtain glows with the spectrum beneath it (softened).
            float bx = clamp(uv.x * 0.8f + 0.1f, 0.0f, 1.0f);
            float e = (band(bands, bx - 0.02f) + band(bands, bx) + band(bands, bx + 0.02f)) / 3;
            float intensity = curtain * rays * (0.14f + level * 0.55f + e * 0.65f + swell * 0.35f);
            // Psychedelic colour: shifts with height, position, time and every beat.
            float hueShift = u.hue + f * 0.17f + max(0.0f, dy) * 1.4f + x * 0.12f + d * 0.015f;
            float3 tint = mix(acid(hueShift), palette(hueShift + 0.3f), 0.35f);
            color += tint * intensity * (1.1f - f * 0.15f);
            // The bright lower edge, crisp but steady.
            color += mix(tint, float3(1), 0.35f) * (core(dy, px * 0.6f, px) * 0.5f + glow(dy, 0.006f) * 0.35f) * (0.25f + treble * 0.55f + swell * 0.3f);
        }
        // A faint reflection on still water at the bottom.
        float horizon = -0.38f;
        if (p.y < horizon) {
            float mirrorY = 2 * horizon - p.y;
            float shimmer = 0.5f + 0.5f * noise(float2(p.x * 30, p.y * 120 + d * 2));
            color += mix(float3(0.1f, 0.6f, 0.5f), acid(u.hue + p.x * 0.2f), 0.5f)
                   * exp(-(mirrorY + 0.1f) * 3) * 0.12f * shimmer * (0.4f + level);
        }
    } else if (style == 2) {                        // Spectrum
        float x = clamp(uv.x * 0.92f + 0.04f, 0.0f, 1.0f), col = floor(x * 64);
        float value = bands[min(63u, uint(col))];
        float top = -0.27f + value * 0.52f;
        // Bar edges anti-aliased over one device pixel (in column units).
        float colPx = 64.0f / (0.92f * u.size.x);
        float inside = 1 - smoothstep(0.40f - colPx * 0.5f, 0.40f + colPx * 0.5f, abs(fract(x * 64) - 0.5f));
        float bar = inside * smoothstep(-0.27f - px, -0.27f + px, p.y) * (1 - smoothstep(top - px, top + px, p.y));
        float3 tint = palette(x * 0.65f + 0.07f + u.hue * 0.5f);
        color += tint * bar * (0.24f + 0.8f * value + kick * 0.25f) * (0.5f + uv.y * 0.6f);
        color += tint * inside * glow(p.y - top, 0.007f + kick * 0.006f) * (0.1f + value * 0.9f);
        float reflectionY = -p.y - 0.54f;
        color += tint * inside * step(-0.27f, reflectionY) * step(reflectionY, top) * exp(-(abs(p.y + 0.27f)) * 18) * 0.12f;
    } else if (style == 3) {                        // Nebula
        float2 q = p * (2.5f - kick * 0.3f);
        float n = fbm(q + float2(d * 0.07f, -d * 0.04f));
        float cloud = pow(max(0.0f, n - 0.28f), 2.0f) * exp(-r * 1.2f);
        color += palette(n * 0.9f + d * 0.015f + u.hue) * cloud * (0.5f + level * 2.4f + kick * 1.2f);
        float curve = r - (0.17f + 0.07f * sin(angle * 3 + d * 0.3f) + circularWave(waves, fract(angle / TAU + 0.5f)) * (0.04f + mid * 0.04f) + bass * 0.05f + kick * 0.03f);
        color += palette(angle / TAU + 0.3f + u.hue) * glow(curve, 0.013f) * (0.15f + mid * 0.8f);
        color += float3(0.7f, 0.85f, 1) * core(curve, px * 0.5f, px) * (0.25f + treble * 0.6f);
    } else if (style == 4) {                        // Kaleidoscope (psychedelic)
        float2 q = rotation(d * 0.12f + kick * 0.25f) * p;
        float segments = 8;
        float a = atan2(q.y, q.x) + TAU * 0.5f;
        float slice = TAU / segments;
        a = abs(fmod(a, slice) - slice * 0.5f);     // fold into one mirrored wedge
        float rr = length(q) * (1 - kick * 0.18f);
        float2 z = float2(cos(a), sin(a)) * rr * (2.6f + bass * 0.8f);
        float glowSum = 0, trap = 10;
        float2 c = float2(0.86f + 0.08f * sin(d * 0.17f), 0.58f + 0.1f * cos(d * 0.13f) + mid * 0.08f);
        for (int j = 0; j < 7; j++) {
            z = abs(z) / max(0.02f, dot(z, z)) - c;
            float l = length(z);
            trap = min(trap, abs(l - 0.6f));
            glowSum += exp(-l * 1.6f);
        }
        float petal = band(bands, a / (slice * 0.5f));
        float3 tint = acid(glowSum * 0.18f + rr * 0.6f + u.hue + d * 0.02f);
        color += tint * (0.25f + level * 0.9f + kick * 0.5f) * (0.35f + glowSum * 0.22f);
        color += acid(u.hue + 0.5f + trap) * exp(-trap * 30) * (0.3f + treble * 1.2f);
        // Band-driven petals bloom from the centre.
        color += acid(petal + u.hue + 0.25f) * glow(rr - 0.12f - petal * 0.32f, 0.01f + kick * 0.01f) * (0.3f + petal);
        color *= 0.75f + 0.25f * sin(rr * 40 - d * 3);
    } else if (style == 5) {                        // Liquid (psychedelic)
        float2 q = p * (1.5f + bass * 0.3f);
        float2 w1 = float2(fbm(q + d * 0.11f), fbm(q + float2(5.2f, 1.3f) - d * 0.09f));
        float2 w2 = float2(fbm(q + (3 + kick * 2) * w1 + float2(1.7f, 9.2f) + d * 0.13f),
                           fbm(q + (3 + kick * 2) * w1 + float2(8.3f, 2.8f)));
        float f = fbm(q + (3 + bass * 3) * w2);
        float3 tint = acid(f * 1.7f + length(w2) * 0.6f + u.hue + d * 0.01f);
        color += tint * (0.3f + level * 0.9f + kick * 0.35f) * (0.45f + f);
        // Bright contour lines through the melt, sharper with treble.
        float rings = abs(sin(f * (22 + mid * 10) + d * 1.5f));
        color += acid(f + 0.5f + u.hue) * pow(1 - rings, 18.0f - treble * 10) * (0.25f + mid * 0.8f);
        // Ripples outward from the centre on bass.
        color *= 1 + 0.3f * sin(r * 28 - d * 6) * (bass + kick * 0.5f);
    } else if (style == 6) {                        // Hyperspace (spacey)
        float a = atan2(p.y, p.x) / TAU + 0.5f;
        color += float3(0.25f, 0.35f, 0.7f) * exp(-r * 5) * (0.2f + level * 0.6f + kick * 0.6f);
        color += palette(u.hue + 0.6f) * fbm(p * 3 + d * 0.05f) * exp(-r * 2) * 0.12f * (1 + level);
        for (int j = 0; j < 4; j++) {
            float layer = float(j);
            float count = 70 + layer * 41;
            float cell = floor(a * count);
            float h = hash21(float2(cell, layer * 13.1f));
            float prog = fract(h * 7.3f + d * (0.18f + h * 0.22f) * (1 + layer * 0.25f));
            float sr = prog * prog * 1.5f;          // perspective: stars speed up outward
            float len = 0.01f + sr * (0.12f + level * 0.35f + kick * 0.5f);
            float along = smoothstep(sr - len, sr, r) * (1 - smoothstep(sr, sr + px * 2, r));
            float across = core((fract(a * count) - 0.5f) / count * TAU * r, px * (0.5f + prog * 1.5f), px);
            float3 tint = mix(float3(0.75f, 0.85f, 1), palette(h + u.hue), 0.35f + treble * 0.3f);
            color += tint * along * across * (0.3f + prog * 1.6f) * (0.6f + treble * 0.8f);
        }
        // The tunnel mouth breathes with the bass and rings on beats.
        float mouth = r - (0.05f + bass * 0.05f);
        color += palette(u.hue) * glow(mouth, 0.02f) * (0.15f + bass * 0.6f);
        color += float3(0.8f, 0.9f, 1) * glow(r - (1 - u.beat) * 0.8f, 0.01f) * u.beat * 0.5f;
    } else {                                        // Galaxy (spacey)
        float2 q = p * (1 - kick * 0.08f);
        float rr = length(q), ang = atan2(q.y, q.x);
        float spiral = ang * 2 + log(rr + 0.002f) * 4.5f - d * 0.22f;
        float arms = pow(0.5f + 0.5f * cos(spiral), 3.0f) * exp(-rr * 2.1f);
        float dust = fbm(float2(spiral * 0.7f, rr * 7) + d * 0.02f);
        color += palette(rr * 0.8f + u.hue + 0.6f) * arms * (0.3f + mid * 1.0f + kick * 0.3f) * (0.5f + dust);
        color -= float3(0.04f) * smoothstep(0.55f, 0.75f, dust) * arms;   // dark dust lanes
        // Stars swirl with differential rotation: inner ones orbit faster.
        float2 sq = rotation(d * 0.06f / (rr + 0.25f)) * q;
        float2 cell = sq * 110, grid = floor(cell);
        float star = step(0.985f, hash21(grid)) * exp(-length(fract(cell) - 0.5f) * 16);
        color += mix(float3(0.8f, 0.85f, 1), palette(hash21(grid) + u.hue), 0.4f) * star * (0.25f + treble * 0.7f + arms * 2);
        // The core swells with the bass and flares on beats.
        color += float3(1, 0.85f, 0.6f) * exp(-rr * (16 - bass * 8)) * (0.45f + bass * 1.4f + kick * 0.8f);
        // A ring of the spectrum orbits the core.
        float ringBand = band(bands, fract(ang / TAU + 0.5f + d * 0.01f));
        float ring = rr - (0.36f + ringBand * 0.07f);
        color += palette(ringBand + u.hue) * core(ring, px * 0.4f, px) * (0.1f + treble * 0.5f);
    }

    color *= 1 - smoothstep(0.35f, 1.15f, r) * 0.65f;
    // Map highlights into display range without crushing bright color channels.
    color = 1 - exp(-max(color, 0.0f) * 1.35f);
    // Triangular dither below one 8-bit step hides banding in the dark gradients.
    float2 fp = in.position.xy;
    float dither = hash21(fp + fract(u.time * 7.0f)) + hash21(fp * 1.37f + 3.1f) - 1.0f;
    // The target is sRGB, so dither in display space or near-black would get loud.
    float3 display = pow(max(color, 0.0f), float3(1.0f / 2.2f)) + dither / 255.0f;
    color = pow(max(display, 0.0f), float3(2.2f));
    return float4(color, 1);
}
