#include <metal_stdlib>
#include "VoiceGlowUniforms.h"

using namespace metal;

struct Varyings {
  float4 position [[position]];
  /// Points from the shell's bottom-left corner. Unflipped, matching
  /// `VoiceEdgeGlowLayout`, where y = 0 is the bottom edge.
  float2 local;
};

vertex Varyings voiceGlowVertex(
  uint id [[vertex_id]],
  constant VoiceGlowUniforms &u [[buffer(VoiceGlowBufferIndexUniforms)]]
) {
  const float2 clip = float2((id == 1) ? 3.0 : -1.0, (id == 2) ? 3.0 : -1.0);
  Varyings out;
  out.position = float4(clip, 0.0, 1.0);
  out.local = (clip * 0.5 + 0.5) * u.size;
  return out;
}

static inline float shellDistance(float2 p, float2 halfSize, float radius, float continuous) {
  const float r = min(radius, min(halfSize.x, halfSize.y));
  const float2 q = abs(p) - halfSize + r;
  const float2 outside = max(q, 0.0);
  const float exponent = mix(2.0, 3.6, continuous);
  const float norm = (outside.x <= 0.0 && outside.y <= 0.0)
    ? 0.0
    : pow(pow(outside.x, exponent) + pow(outside.y, exponent), 1.0 / exponent);
  return norm + min(max(q.x, q.y), 0.0) - r;
}

static inline float ditherNoise(float2 p) {
  return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
}

static inline float lattice(float2 cell) {
  float2 p = fract(cell * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

static inline float rayNoise(float x, float period, float y, float seed) {
  const float i = floor(x);
  const float fx = x - i;
  const float j = floor(y);
  const float fy = y - j;

  const float i0 = i - period * floor(i / period);
  float i1 = i0 + 1.0;
  i1 = (i1 >= period) ? 0.0 : i1;

  const float a = lattice(float2(i0 + seed, j));
  const float b = lattice(float2(i1 + seed, j));
  const float c = lattice(float2(i0 + seed, j + 1.0));
  const float d = lattice(float2(i1 + seed, j + 1.0));

  const float sx = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0);
  const float sy = fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0);
  return mix(mix(a, b, sx), mix(c, d, sx), sy);
}

static inline float3 ringColor(constant VoiceGlowUniforms &u, float v) {
  const float pos = saturate(v) * float(VOICE_GLOW_COLOR_COUNT - 1);
  const int i = min(int(floor(pos)), VOICE_GLOW_COLOR_COUNT - 2);
  const float f = smoothstep(0.0, 1.0, pos - float(i));
  return mix(u.colors[i].rgb, u.colors[i + 1].rgb, f);
}

static inline float3 paletteLight(constant VoiceGlowUniforms &u, float n, float level, float carry);

static inline float3 rayColour(
  constant VoiceGlowUniforms &u, float turnPhase, float rho, float level, thread float &n1
) {
  const float wind = u.beam * 1.9 * log2(1.0 + rho * 1.6) * (1.0 / 6.2831853);
  const float a = turnPhase + wind;

  const float f = u.flow;
  n1 = rayNoise(a * 7.0 + f * 0.50, 7.0, rho * 0.80 - f * 0.20, 1.0);
  const float n2 = rayNoise(a * 13.0 - f * 0.78, 13.0, rho * 1.15 - f * 0.34, 17.0);
  const float n3 = rayNoise(a * 22.0 + f * 1.25, 22.0, rho * 1.90 - f * 0.55, 31.0);

  // Averaging three noises piles the values up in the middle, which would draw
  // every ray the same mid-palette colour. Stretched about the middle, so the
  // rays reach both ends of what they are given — more so the louder it is.
  const float gain = 2.0 + 1.6 * level;
  const float n = saturate((n1 * 0.52 + n2 * 0.31 + n3 * (0.17 + 0.10 * level) - 0.5) * gain + 0.5);

  return paletteLight(u, n, level, 0.8);
}

static inline float3 paletteLight(constant VoiceGlowUniforms &u, float n, float level, float carry) {
  const float f = u.flow;
  const float span = mix(0.46, 1.0, level);
  const float centre = 0.5 + 0.30 * sin(f * 0.23 + 1.0) + 0.14 * sin(f * 0.57 + 4.0);
  float3 colour = ringColor(u, saturate(centre + (n - 0.5) * span));

  const float luma = dot(colour, float3(0.2126, 0.7152, 0.0722));
  colour = saturate(mix(float3(luma), colour, 1.35));

  // A palette's pale stop is the brightest thing in it and would take white
  // words, or a light band, with it — so what is close to white is carried
  // toward the palette's first stop, its body colour, rather than darkened to
  // grey, which was a plateau of nothing. By the *smallest* channel, not by
  // brightness: a yellow is bright and still a colour, and darkening it by
  // brightness turned it to olive.
  const float whiteness = smoothstep(0.50, 0.88, min(colour.r, min(colour.g, colour.b)));
  return mix(colour, u.colors[0].rgb * 0.92, whiteness * carry);
}

fragment float4 voiceGlowFragment(
  Varyings in [[stage_in]],
  constant VoiceGlowUniforms &u [[buffer(VoiceGlowBufferIndexUniforms)]]
) {
  const float2 p = in.local;
  const float2 halfSize = u.size * 0.5;
  const float distance = shellDistance(p - halfSize, halfSize, u.cornerRadius, u.cornerIsContinuous);
  const float aa = max(u.pixelSize, 0.25);
  const float level = saturate(u.intensity);
  const float grain = ditherNoise(in.position.xy) * (1.0 / 255.0);

  if (u.orb > 0.0) {
    return float4(0.0);
  }

  const float clip = 1.0 - smoothstep(-aa, 0.0, distance + 1.0);
  if (clip <= 0.0 || u.opacity <= 0.0 || p.y >= u.reach * 1.45) {
    return float4(0.0);
  }

  const float2 d = p - u.origin;
  const float unit = max(u.size.y, 32.0);
  const float rho = length(d) / unit;
  float n1 = 0.0;
  float3 colour = rayColour(u, atan2(d.y, d.x) * (1.0 / 6.2831853), rho, level, n1);

  const float ripple = sin(rho * 6.5 - u.flow * 3.2 + n1 * 6.2831853);
  const float lit = 0.90 + 0.10 * ripple * (0.35 + 0.65 * level);

  const float core = exp(-rho * 1.5);
  colour = mix(colour, float3(1.0), core * (0.14 + 0.26 * level));
  const float crown = mix(1.0, 0.80, smoothstep(0.30, 1.0, p.y / max(u.size.y, 1.0)));

  const float exposure = mix(1.0, 0.82, u.appearance);
  colour *= lit * crown * exposure * (0.90 + 0.10 * level);

  const float foot = 1.0 - smoothstep(u.reach, u.reach * 1.45, p.y);

  float4 picture = float4(colour, 1.0) * foot;

  const float coverage = clip * u.opacity * 0.96;
  picture *= coverage;
  return float4(saturate(picture.rgb + grain * picture.a), saturate(picture.a));
}
