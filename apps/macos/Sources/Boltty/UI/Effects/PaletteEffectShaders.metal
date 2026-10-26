#include <metal_stdlib>
#include "PaletteEffectUniforms.h"

using namespace metal;

struct EffectVaryings {
  float4 position [[position]];
  float2 local;
};

static inline EffectVaryings coverViewport(uint id, float2 size) {
  const float2 clip = float2((id == 1) ? 3.0 : -1.0, (id == 2) ? 3.0 : -1.0);
  EffectVaryings out;
  out.position = float4(clip, 0.0, 1.0);
  out.local = (clip * 0.5 + 0.5) * size;
  return out;
}

static inline float roundedDistance(float2 p, float2 halfSize, float radius, float continuous) {
  const float r = min(radius, min(halfSize.x, halfSize.y));
  const float2 q = abs(p) - halfSize + r;
  const float2 outside = max(q, 0.0);
  const float exponent = mix(2.0, 3.6, continuous);
  const float norm = (outside.x <= 0.0 && outside.y <= 0.0)
    ? 0.0
    : pow(pow(outside.x, exponent) + pow(outside.y, exponent), 1.0 / exponent);
  return norm + min(max(q.x, q.y), 0.0) - r;
}

constexpr sampler effectSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// MARK: - Reveal

vertex EffectVaryings revealVertex(
  uint id [[vertex_id]],
  constant PaletteRevealUniforms &u [[buffer(PaletteEffectBufferIndexUniforms)]]
) {
  return coverViewport(id, u.size);
}

static inline float2 revealUV(float2 p, constant PaletteRevealUniforms &u) {
  float2 uv = p / u.size;
  uv = (uv - 0.5) / max(u.zoom, 0.01) + 0.5;
  const float viewAspect = u.size.x / max(u.size.y, 1.0);
  if (u.imageAspect > viewAspect) {
    uv.x = 0.5 + (uv.x - 0.5) * viewAspect / u.imageAspect;
  } else {
    uv.y = 0.5 + (uv.y - 0.5) * u.imageAspect / viewAspect;
  }
  return float2(uv.x, 1.0 - uv.y);
}

fragment float4 revealFragment(
  EffectVaryings in [[stage_in]],
  constant PaletteRevealUniforms &u [[buffer(PaletteEffectBufferIndexUniforms)]],
  texture2d<float> image [[texture(PaletteEffectTextureIndexImage)]]
) {
  const float2 halfSize = u.size * 0.5;
  const float distance = roundedDistance(
    in.local - halfSize, halfSize, u.cornerRadius, u.cornerIsContinuous);
  const float aa = max(u.pixelSize, 0.25);
  const float coverage = 1.0 - smoothstep(-aa, 0.0, distance);
  if (coverage <= 0.0 || u.opacity <= 0.0) {
    return float4(0.0);
  }

  const float2 split = float2(u.aberration, 0.0);
  const float golden = 2.39996323;
  float4 sum = float4(0.0);
  float weight = 0.0;
  for (int i = 0; i < 24; i++) {
    const float t = (float(i) + 0.5) / 24.0;
    const float radius = sqrt(t) * u.blur;
    const float angle = float(i) * golden;
    const float2 offset = float2(cos(angle), sin(angle)) * radius;
    const float w = 1.0 - 0.6 * t;
    const float r = image.sample(effectSampler, revealUV(in.local + offset - split, u)).r;
    const float4 g = image.sample(effectSampler, revealUV(in.local + offset, u));
    const float b = image.sample(effectSampler, revealUV(in.local + offset + split, u)).b;
    sum += float4(r, g.g, b, g.a) * w;
    weight += w;
  }
  float4 colour = sum / max(weight, 0.0001);
  colour.rgb = min(colour.rgb, float3(colour.a));
  return colour * (u.opacity * coverage);
}

// MARK: - Whip

vertex EffectVaryings whipVertex(
  uint id [[vertex_id]],
  constant PaletteWhipUniforms &u [[buffer(PaletteEffectBufferIndexUniforms)]]
) {
  return coverViewport(id, u.size);
}

fragment float4 whipFragment(
  EffectVaryings in [[stage_in]],
  constant PaletteWhipUniforms &u [[buffer(PaletteEffectBufferIndexUniforms)]],
  texture2d<float> image [[texture(PaletteEffectTextureIndexImage)]]
) {
  if (u.opacity <= 0.0) {
    return float4(0.0);
  }
  const float2 origin = u.frame.xy;
  const float2 extent = max(u.frame.zw, float2(1.0));
  const float2 centre = origin + extent * 0.5;
  const float speed = length(u.velocity);
  float2 q = in.local;
  if (speed > 1.0 && u.lag > 0.0) {
    const float2 heading = u.velocity / speed;
    const float span = max(abs(heading.x) * extent.x + abs(heading.y) * extent.y, 1.0);
    const float along = dot(in.local - centre, heading);
    const float behind = clamp((span * 0.5 - along) / (span + u.lag), 0.0, 1.0);
    const float2 across = float2(-heading.y, heading.x);
    const float width = max(abs(across.x) * extent.x + abs(across.y) * extent.y, 1.0) * 0.5;
    const float side = clamp(dot(in.local - centre, across) / width, -1.0, 1.0);
    const float drop = 1.0 - 0.55 * side * side;
    q = in.local + heading * u.lag * behind * behind * drop;
  }
  const float2 halfSize = extent * 0.5;
  const float distance = roundedDistance(q - centre, halfSize, u.cornerRadius, 0.0);
  const float aa = max(u.pixelSize, 0.25);
  const float coverage = 1.0 - smoothstep(-aa, 0.0, distance);
  if (coverage <= 0.0) {
    return float4(0.0);
  }
  float2 uv = (q - origin) / extent;
  uv.y = 1.0 - uv.y;
  return image.sample(effectSampler, uv) * (u.opacity * coverage);
}

// MARK: - Selection glow

vertex EffectVaryings selectionGlowVertex(
  uint id [[vertex_id]],
  constant PaletteSelectionGlowUniforms &u [[buffer(PaletteEffectBufferIndexUniforms)]]
) {
  return coverViewport(id, u.size);
}

static inline float pingPong(float x) {
  const float m = x - 2.0 * floor(x * 0.5);
  return 1.0 - abs(1.0 - m);
}

static inline float3 glowColour(float t, constant PaletteSelectionGlowUniforms &u) {
  const float scaled = saturate(t) * float(PaletteSelectionGlowStops - 1);
  const int i = min(int(floor(scaled)), PaletteSelectionGlowStops - 2);
  return mix(u.colors[i].rgb, u.colors[i + 1].rgb, scaled - float(i));
}

fragment float4 selectionGlowFragment(
  EffectVaryings in [[stage_in]],
  constant PaletteSelectionGlowUniforms &u [[buffer(PaletteEffectBufferIndexUniforms)]]
) {
  const float2 origin = u.region.xy;
  const float2 extent = max(u.region.zw, float2(1.0));
  const float d = roundedDistance(in.local - (origin + 0.5 * extent), 0.5 * extent, u.cornerRadius, 0.0);

  const float2 uv = (in.local - origin) / extent;
  const float wave = u.waveAmplitude
    * (sin(uv.x * 5.7 + u.clock * 0.8) + 0.56 * sin(uv.x * 11.1 - u.clock * 0.55 + 1.7));
  const float drift = u.driftAmplitude * sin(u.clock * 0.35);
  const float3 colour = glowColour(pingPong((1.0 - uv.y) + wave + drift), u);

  const float aa = u.pixelSize;
  const float halfLine = 0.5 * u.lineWidth;
  const float line = 1.0 - smoothstep(halfLine - aa, halfLine + aa, abs(d));
  const float sigma = 0.45 * max(1.0, u.glowDepth);
  const float2 fromLow = max(in.local - origin, float2(0.0)) / sigma;
  const float2 fromHigh = max(origin + extent - in.local, float2(0.0)) / sigma;
  const float dark = (1.0 - exp(-fromLow.x * fromLow.x)) * (1.0 - exp(-fromHigh.x * fromHigh.x))
    * (1.0 - exp(-fromLow.y * fromLow.y)) * (1.0 - exp(-fromHigh.y * fromHigh.y));
  const float inside = d < 0.0 ? u.glowStrength * (1.0 - dark) : 0.0;
  const float outside = d > 0.0
    ? u.haloStrength * pow(1.0 - saturate(d / max(u.haloReach, 1.0)), 2.0) : 0.0;
  const float alpha = saturate(line + (1.0 - line) * (inside + outside));
  return float4(colour * alpha, alpha);
}
