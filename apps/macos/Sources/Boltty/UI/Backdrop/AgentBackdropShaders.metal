#include <metal_stdlib>
#include "AgentBackdropUniforms.h"
#include "../Effects/OklabShading.h"

using namespace metal;

struct BackdropVaryings {
  float4 position [[position]];
  float2 local;
};

vertex BackdropVaryings agentBackdropVertex(
  uint id [[vertex_id]],
  constant AgentBackdropUniforms &u [[buffer(AgentBackdropBufferIndexUniforms)]]
) {
  const float2 clip = float2((id == 1) ? 3.0 : -1.0, (id == 2) ? 3.0 : -1.0);
  BackdropVaryings out;
  out.position = float4(clip, 0.0, 1.0);
  out.local = (clip * 0.5 + 0.5) * u.size;
  return out;
}

static inline float backdropHash(float2 p) {
  p = fract(p * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

static inline float backdropNoise(float2 p) {
  const float2 i = floor(p);
  const float2 f = fract(p);
  const float2 w = f * f * (3.0 - 2.0 * f);
  const float a = backdropHash(i);
  const float b = backdropHash(i + float2(1, 0));
  const float c = backdropHash(i + float2(0, 1));
  const float d = backdropHash(i + float2(1, 1));
  return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

static inline float backdropFBM(float2 p, int octaves) {
  const float2x2 turn = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
  float sum = 0.0;
  float amplitude = 0.5;
  for (int octave = 0; octave < octaves; octave++) {
    sum += amplitude * backdropNoise(p);
    p = turn * p * 2.03 + float2(17.1, 9.2);
    amplitude *= 0.5;
  }
  return sum;
}

static inline float backdropFBM(float2 p) { return backdropFBM(p, 5); }

static float3 backdropSky(float2 local, float2 size, float t, constant float4 *lab) {
  const float h = local.y / size.y;
  const float2 uv = local / 420.0;
  const float3 zenith = lab[0].xyz;
  const float3 horizon = lab[1].xyz;
  const float3 sunlight = lab[2].xyz;
  const float3 underside = lab[3].xyz;
  const float3 middle = lab[4].xyz;
  const float3 glow = lab[5].xyz;

  const float x = local.x / size.x;
  const float lean = (backdropFBM(local / size * 1.3 + float2(t * 0.006, 0.0), 3) - 0.5) * 0.3;
  const float g = clamp(h * 0.85 + (0.5 - x) * 0.25 + lean, 0.0, 1.0);
  float3 color = mix(horizon, middle, smoothstep(0.0, 0.5, g));
  color = mix(color, zenith, smoothstep(0.42, 0.95, g));
  const float2 sunAt = float2(size.x * 0.78, -size.y * 0.06);
  const float sun = exp(-pow(length((local - sunAt) / float2(size.x * 0.75, size.y * 0.5)), 1.4) * 1.8);
  color = mix(color, glow, sun * 0.75);

  const float3 scales = float3(2.1, 1.4, 0.95);
  const float3 speeds = float3(0.0125, 0.023, 0.036);
  const float3 bands = float3(0.7, 0.45, 0.18);
  const float3 haze = float3(0.45, 0.2, 0.0);
  const float3 softness = float3(0.2, 0.13, 0.09);

  for (int layer = 0; layer < 3; layer++) {
    const float2 p = float2(uv.x * 0.5, uv.y) * scales[layer]
      + float2(t * speeds[layer], 0.0) + float2(float(layer) * 11.7, float(layer) * 3.9);
    const float2 warp = float2(
      backdropFBM(p * 0.55 + float2(0.0, t * 0.02), 3),
      backdropFBM(p * 0.55 + float2(5.2, 1.3) - t * 0.016, 3)
    ) - 0.5;
    const float2 at = p + 0.6 * warp;
    const float density = backdropFBM(at, 4);
    const float band = exp(-pow((h - bands[layer]) / 0.22, 2.0));
    const float threshold = mix(0.6, 0.36, band);
    const float cloud = smoothstep(threshold, threshold + softness[layer], density);
    if (cloud <= 0.001) { continue; }

    const float toward = backdropFBM(at + float2(0.05, 0.16), 4);
    const float lit = clamp((density - toward) * 5.0 + 0.4, 0.0, 1.0);
    const float thick = smoothstep(threshold + 0.04, threshold + 0.32, density);
    const float3 under = mix(float3(horizon.x * 0.865, horizon.yz), underside, smoothstep(0.2, 0.62, h));
    const float3 shade = mix(under, color, 0.5);
    const float3 lowLight = mix(sunlight, glow, 0.3 + sun * 0.3 + (1.0 - smoothstep(0.0, 0.5, h)) * 0.25);
    const float3 skyLight = float3(min(color.x * 1.47 + 0.05, 0.97), color.yz);
    const float3 light = mix(lowLight, skyLight, smoothstep(0.5, 0.85, h) * 0.85);
    float3 body = mix(shade, light, lit * mix(1.0, 0.6, thick));
    body += light * (1.0 - thick) * lit * 0.3;
    body = mix(body, color, haze[layer]);
    color = mix(color, body, cloud);
  }

  return oklabToSRGB(oklabCeiling(color, 0.39, 0.62));
}

// Brightnesses were judged on encoded values, hence the 2.2; coverage stays linear.
static inline float asLight(float brightness) { return pow(max(brightness, 0.0), 2.2); }

static float3 backdropStarTint(float k, float3 face) {
  const float3 blue = oklch(0.86, 0.06, 258.0);
  const float3 white = oklch(1.0, 0.0, 0.0);
  const float3 warm = oklch(0.90, 0.075, 72.0);
  float3 c = mix(blue, white, smoothstep(0.0, 0.35, k));
  c = mix(c, warm, smoothstep(0.75, 1.0, k));
  const float3 lit = float3(c.x, face.yz);
  return mix(c, lit, step(0.82, fract(k * 7.31)) * 0.6);
}

static float3 backdropStarLayer(
  float2 local, float cellSize, float chance, float radius, float drift, float seed,
  float margin, bool rays, float gain, float t, float pixel, float3 face
) {
  const float2 at = local + float2(t * drift, 0.0);
  const float2 cell = floor(at / cellSize);
  const float crowd = smoothstep(0.32, 0.72, backdropFBM(cell * cellSize / 300.0 + seed, 3));
  const float pick = backdropHash(cell + seed);
  if (pick > chance * mix(0.35, 1.7, crowd)) { return float3(0.0); }
  const float2 jitter = float2(backdropHash(cell + seed + 3.1), backdropHash(cell + seed + 7.7));
  const float2 centre = (cell + margin + (1.0 - 2.0 * margin) * jitter) * cellSize;
  const float magnitude = pow(backdropHash(cell + seed + 1.9), 3.0);
  const float size = radius * (0.55 + 0.9 * magnitude);
  const float2 d = at - centre;
  const float distance = length(d);
  // Never thinner than a pixel, or a faint star flickers as it drifts.
  const float r = max(size, pixel * 0.75);
  const float twinkle = 1.0 - (0.45 - 0.3 * magnitude)
    * (0.5 + 0.5 * sin(t * (0.6 + jitter.x * 1.6) + jitter.y * 40.0));
  const float bright = asLight((0.35 + 0.65 * magnitude) * twinkle * gain);
  float light = smoothstep(r + pixel, max(r - pixel, 0.0), distance) * bright;
  light += exp(-distance / (r * 1.6)) * 0.06 * magnitude * bright;
  if (rays && magnitude > 0.45) {
    const float reach = r * 9.0;
    const float along = 1.0 - smoothstep(0.0, reach, max(abs(d.x), abs(d.y)));
    const float thin = exp(-min(abs(d.x), abs(d.y)) / max(pixel, 0.35));
    light += along * along * thin * 0.12 * smoothstep(0.45, 1.0, magnitude) * bright;
  }
  return oklabToLight(backdropStarTint(backdropHash(cell + seed + 5.3), face)) * light;
}

static float3 backdropSpace(float2 local, float2 size, float t, float pixel, constant float4 *lab) {
  const float h = local.y / size.y;
  const float x = local.x / size.x;
  const float3 zenith = lab[0].xyz;
  const float3 face = lab[2].xyz;
  const float3 middle = lab[4].xyz;
  const float3 glow = lab[5].xyz;

  const float breath = backdropFBM(local / 380.0 + float2(t * 0.004, 0.0), 3);
  const float lean = backdropFBM(local / size * 1.1 + float2(t * 0.005, 3.7), 3) - 0.5;
  const float r = length(float2((x - 0.5) * size.x, (h - 0.45) * size.y)) / (0.55 * max(size.x, size.y));
  const float g = clamp(r * 0.8 + lean * 0.7, 0.0, 1.0);
  const float3 heart = mix(middle, glow, 0.3);
  float3 hue = mix(heart, middle, smoothstep(0.05, 0.85, g));
  hue = mix(hue, zenith, smoothstep(0.45, 1.0, g));
  const float chroma = length(hue.yz);
  const float2 toward = chroma > 1e-4 ? hue.yz / chroma : float2(0.0);
  const float depth = 0.105 + 0.02 * breath;
  float3 light = oklabToLight(float3(depth, toward * min(chroma * 0.22, 0.026)));
  const float centre = exp(-r * r * 1.8);
  const float3 soft = float3(heart.x, heart.yz * 0.35);
  light += oklabToLight(soft) * centre * asLight(0.06 + 0.02 * breath);

  float3 stars = backdropStarLayer(local, 7.0, 0.11, 0.3, 0.5, 0.0, 0.15, false, 0.45, t, pixel, face);
  stars += backdropStarLayer(local, 16.0, 0.13, 0.5, 0.9, 17.0, 0.15, false, 0.75, t, pixel, face);
  stars += backdropStarLayer(local, 38.0, 0.12, 0.8, 1.5, 41.0, 0.2, false, 1.1, t, pixel, face);
  stars += backdropStarLayer(local, 84.0, 0.26, 1.1, 2.4, 73.0, 0.25, true, 1.15, t, pixel, face);
  light += stars;

  const float period = 11.0;
  const float which = floor(t / period);
  const float age = fract(t / period) * period;
  if (age < 0.9) {
    const float2 from = float2(size.x * (0.25 + 0.6 * backdropHash(float2(which, 1.0))),
                               size.y * (0.7 + 0.25 * backdropHash(float2(which, 2.0))));
    const float2 heading = normalize(float2(-1.0, -0.42));
    const float2 head = from + heading * age * 420.0;
    const float2 rel = local - head;
    const float along = dot(rel, -heading);
    const float across = abs(dot(rel, float2(-heading.y, heading.x)));
    const float tail = smoothstep(110.0, 0.0, along) * step(0.0, along);
    const float streak = tail * smoothstep(0.9 + pixel, 0.0, across);
    const float fade = smoothstep(0.0, 0.1, age) * smoothstep(0.9, 0.55, age);
    const float3 white = oklch(1.0, 0.0, 0.0);
    light += oklabToLight(mix(white, float3(white.x, face.yz), 0.25)) * streak * fade * asLight(0.8);
  }

  float3 color = oklabCeiling(linearToOklab(light), 0.35, 0.565);
  color.x *= mix(1.0, 0.557, smoothstep(0.62, 1.0, h));
  return oklabToSRGB(color);
}

fragment float4 agentBackdropFragment(
  BackdropVaryings in [[stage_in]],
  constant AgentBackdropUniforms &u [[buffer(AgentBackdropBufferIndexUniforms)]]
) {
  if (u.opacity <= 0.0) { return float4(0.0); }
  const float2 size = max(u.size, float2(1.0));
  const float h = in.local.y / size.y;
  const float t = u.clock;

  float3 color;
  if (u.scene > 1.5) {
    color = backdropSpace(in.local, size, t, u.pixelSize, u.sky);
  } else {
    color = backdropSky(in.local, size, t, u.sky);
    color *= mix(1.0, 0.45, smoothstep(0.62, 1.0, h));
  }
  color += (backdropHash(in.position.xy + fract(t)) - 0.5) / 255.0;

  return float4(max(color, 0.0) * u.opacity, u.opacity);
}
