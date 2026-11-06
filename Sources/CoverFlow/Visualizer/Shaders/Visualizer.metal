#include <metal_stdlib>
using namespace metal;
struct Uniforms { float2 size; float time; float style; float4 audio; float onset; float motion; float2 padding; };
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut visualizerVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2 - 1, 0, 1), p};
}
float hash21(float2 p) { return fract(sin(dot(p, float2(127.1,311.7))) * 43758.5453); }
float noise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f*f*(3-2*f);
    return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x), mix(hash21(i+float2(0,1)),hash21(i+1),f.x), f.y);
}
float band(device const float *bands, float value) {
    float i = clamp(value, 0.0f, 1.0f) * 63;
    uint low = uint(i); return mix(bands[low], bands[min(63u, low+1)], fract(i));
}
float wave(device const float *waves, float value) {
    float i = clamp(value, 0.0f, 1.0f) * 511;
    uint low = uint(i); return mix(waves[low],waves[min(511u,low+1)],fract(i));
}
float circularWave(device const float *waves, float a) {
    // Fade the waveform into the wrap point so circular styles have no radial seam.
    float seam = smoothstep(0.0f, 0.08f, min(a, 1-a));
    return wave(waves,a)*seam;
}
float3 palette(float x) { return 0.55 + 0.45*cos(6.28318*(float3(0.05,0.33,0.58)+x)); }
float glow(float distance, float width) { return exp(-abs(distance)/max(0.0001f,width)); }
// A crisp, anti-aliased line core: full strength within `half` of the curve, fading
// to nothing over about one device pixel, so edges stay sharp at any resolution.
float core(float distance, float half, float px) { return 1 - smoothstep(half, half + px*1.25f, abs(distance)); }
fragment float4 visualizerFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                    device const float *bands [[buffer(1)]], device const float *waves [[buffer(2)]]) {
    float2 uv = in.uv;
    float2 p = (uv-0.5)*float2(u.size.x/u.size.y,1);
    float t = u.time * u.motion;
    float r = length(p), angle = atan2(p.y,p.x);
    float bass=u.audio.x, mid=u.audio.y, treble=u.audio.z, level=u.audio.w;
    float px=1.0/u.size.y;          // one device pixel in p units
    float haze=noise(p*2.2+float2(t*.025,0));
    float3 color=float3(.003,.006,.016)+float3(.008,.012,.032)*haze;
    // Fine, stable stars: energy changes their radiance, never a full-screen flash.
    float2 cell=p*85, grid=floor(cell);
    float star=step(.991,hash21(grid))*exp(-length(fract(cell)-.5)*19);
    color += palette(hash21(grid+10))*star*(.12+treble*.3);
    if (u.style < .5) {
        float a=fract(angle/6.283185+0.5);
        float power=band(bands,abs(a*2-1));
        float radius=.23+bass*.035;
        float d=r-radius-power*.12;
        color += palette(a+t*.015)*(glow(d,.011)*(.3+power)+core(d,px*.6,px)*1.6);
        float inner=r-radius*.86-circularWave(waves,a)*.023;
        color += float3(.35,.8,1)*(glow(inner,.003)*.6+core(inner,px*.4,px))*(.15+mid*.8);
        color += palette(a+.35)*glow(r-radius-.02,.045)*(.025+u.onset*.12);
        for(int j=0;j<3;j++) {
            float orbit=radius+.05+float(j)*.025+sin(angle*3+t*.2+float(j))* .009*mid;
            color += palette(a+float(j)*.16)*core(r-orbit,px*.3,px)*(.05+treble*.16);
        }
    } else if (u.style < 1.5) {
        for(int j=0;j<4;j++) {
            float f=float(j);
            float line=sin(p.x*2+t*.15+f*.8)*(.08+bass*.08)+(f-1.5)*.07;
            line+=wave(waves,uv.x)*(.05+mid*.045);
            float d=p.y-line;
            color += palette(uv.x*.3+f*.13+t*.012)*(glow(d,.035)*(.08+level*.3)+core(d,px*.55,px)*(.45+treble*.8));
        }
    } else if (u.style < 2.5) {
        float x=clamp(uv.x*.92+.04,0.0f,1.0f), col=floor(x*64);
        float value=bands[min(63u,uint(col))];
        float top=-.27+value*.52;
        // Bar edges anti-aliased over one device pixel (in column units).
        float colPx=64.0/(.92*u.size.x);
        float inside=1-smoothstep(.40-colPx*.5,.40+colPx*.5,abs(fract(x*64)-.5));
        float bar=inside*smoothstep(-.27-px,-.27+px,p.y)*(1-smoothstep(top-px,top+px,p.y));
        color += palette(x*.65+.07)*bar*(.24+.75*value)*(0.5+uv.y*.6);
        color += palette(x*.65+.07)*inside*glow(p.y-top,.007)*(.1+value*.8);
        float reflectionY=-p.y-.54;
        color += palette(x*.65+.07)*inside*step(-.27,reflectionY)*step(reflectionY,top)*exp(-(abs(p.y+.27))*18)*.12;
    } else {
        float2 q=p*2.5;
        float n=0, weight=.5;
        for(int j=0;j<4;j++) { n+=weight*noise(q+float2(t*.035,-t*.02));q=q*2.03+float2(5.2,1.3);weight*=.5; }
        float cloud=pow(max(0.0f,n-.28),2.0f)*exp(-r*1.2);
        color += palette(n*.9+t*.008)*cloud*(.5+level*2);
        float curve=r-(.17+.07*sin(angle*3+t*.1)+circularWave(waves,fract(angle/6.28318+.5))*.04+bass*.035);
        color += palette(angle/6.28318+.3)*glow(curve,.013)*(.15+mid*.7);
        color += float3(.7,.85,1)*core(curve,px*.5,px)*(.25+treble*.6);
    }
    color*=1-smoothstep(.35,1.15,r)*.65;
    // Map highlights into display range without crushing bright color channels.
    color=1-exp(-max(color,0.0f)*1.35);
    // Triangular dither below one 8-bit step hides banding in the dark gradients.
    float2 fp=in.position.xy;
    float dither=hash21(fp+fract(u.time*7.0))+hash21(fp*1.37+3.1)-1.0;
    // The target is sRGB, so dither in display space or near-black would get loud.
    float3 display=pow(max(color,0.0f),float3(1.0/2.2))+dither/255.0;
    color=pow(max(display,0.0f),float3(2.2));
    return float4(color,1);
}
