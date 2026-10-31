//  AgentBackdropShaders.metal
//
//  What an open chat wears behind its transcript, in the agent's own
//  colours (`ChatBackdrop`): a dusk sky, deep space, or a rain of mascot silhouettes.
//
//  The sky is after Messages' Sky backgrounds, read off the system's
//  `DynamicBackgroundPosterExtension` (`clouds.vfx`): there each cloud is a
//  large sprite cut from a packed cloud texture, its UVs pushed about by two
//  scrolling noise samples, its edge choked with a `smoothstep`, and tinted by
//  a vertical ramp; three depths (far, middle, near) drift at their own
//  speeds, and a preset is only another row of the ramps. Here the sprite is
//  replaced by domain-warped noise, so nothing of theirs ships and the shapes
//  never repeat; the ramp is the face's gradient.
//
//  Every scene is dark at the top on purpose: the answer is white prose on
//  this, and the shell's other states wear a black ramp there too. The corner
//  is the view layer's, not this file's (see `AgentBackdropUniforms.scene`).

#include <metal_stdlib>
#include "AgentBackdropUniforms.h"

using namespace metal;

struct BackdropVaryings {
  float4 position [[position]];
  /// Points from the shell's bottom-left corner; y = 0 is the foot.
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

/// `octaves` of noise, each turned against the last so no grid shows through.
/// Soft things need fewer: an octave past what a shape shows is pure cost.
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

/// Walks the face's stops, 0 = the first, 1 = the last.
static inline float3 backdropWalk(constant float4 *colors, float t) {
  const float scaled = clamp(t, 0.0, 1.0) * float(AGENT_BACKDROP_COLOR_COUNT - 1);
  const int index = min(int(scaled), AGENT_BACKDROP_COLOR_COUNT - 2);
  return mix(colors[index].rgb, colors[index + 1].rgb, smoothstep(0.0, 1.0, scaled - float(index)));
}

/// `c` scaled down, never up, to relative luminance `target`.
static inline float3 backdropAtLightness(float3 c, float target) {
  const float y = dot(c, float3(0.2126, 0.7152, 0.0722));
  return y > target ? c * (target / y) : c;
}

static inline float3 backdropLuminanceOnly(float3 c, float amount) {
  const float y = dot(c, float3(0.2126, 0.7152, 0.0722));
  return mix(float3(y), c, amount);
}

// MARK: - Sky

static float3 backdropSky(float2 local, float2 size, float t, constant float4 *colors) {
  // Height 0 at the foot, 1 at the top; uv square, so clouds keep their shape
  // as the chat is resized.
  const float h = local.y / size.y;
  const float2 uv = local / 340.0;
  
  // The sky: the face's warm end low, its first stop as a dim dusk overhead.
  const float3 horizon = backdropWalk(colors, 0.9) * 0.62;
  const float3 middle = backdropLuminanceOnly(backdropWalk(colors, 0.45), 0.8) * 0.22;
  const float3 zenith = colors[0].rgb * 0.05;
  float3 sky = mix(horizon, middle, smoothstep(0.0, 0.42, h));
  sky = mix(sky, zenith, smoothstep(0.3, 0.95, h));
  // The sun just under the foot, a glow rather than a disc.
  const float2 sunAt = float2(size.x * 0.62, -size.y * 0.08);
  const float sun = exp(-length((local - sunAt) / float2(size.x * 0.55, size.y * 0.32)) * 2.2);
  sky += backdropWalk(colors, 0.75) * sun * 0.45;

  // A few stars, only where the sky is darkest.
  const float2 cell = floor(local / 9.0);
  const float star = step(0.985, backdropHash(cell));
  const float2 starAt = (cell + 0.2 + 0.6 * float2(backdropHash(cell + 3.1), backdropHash(cell + 7.7))) * 9.0;
  const float twinkle = 0.55 + 0.45 * sin(t * (0.6 + backdropHash(cell + 1.3) * 1.4) + backdropHash(cell) * 40.0);
  sky += star * smoothstep(1.1, 0.0, length(local - starAt)) * twinkle * smoothstep(0.55, 0.9, h) * 0.5;

  // Far, middle and near: each larger, faster, denser and lower than the last
  // — the same three depths as Messages' BG, MG and FG.
  const float3 scales = float3(2.4, 1.55, 1.0);
  const float3 speeds = float3(0.010, 0.017, 0.028);
  const float3 strengths = float3(0.55, 0.7, 0.85);
  const float3 bands = float3(0.62, 0.42, 0.22);

  float3 color = sky;
  for (int layer = 0; layer < 3; layer++) {
    // Wider than tall, as clouds lie in a sky.
    const float2 p = float2(uv.x * 0.55, uv.y) * scales[layer]
      + float2(t * speeds[layer], 0.0) + float2(float(layer) * 11.7, float(layer) * 3.9);
    // Two slow noises push the shape about, as Messages' two scrolling
    // samples push its sprite's UVs. Gently: pushed harder it reads as smoke.
    const float2 warp = float2(
      backdropFBM(p * 0.6 + float2(0.0, t * 0.010)),
      backdropFBM(p * 0.6 + float2(5.2, 1.3) - t * 0.008)
    ) - 0.5;
    const float2 at = p + 0.75 * warp;
    const float density = backdropFBM(at);
    // A band of weather per layer, so the sky is not covered evenly.
    const float band = exp(-pow((h - bands[layer]) / 0.24, 2.0));
    const float threshold = mix(0.68, 0.47, band);
    // The choke: a soft edge, not a fog.
    const float cloud = smoothstep(threshold, threshold + 0.16, density);
    if (cloud <= 0.001) { continue; }

    // Lit from the horizon: where the cloud thins toward the light, it glows.
    const float toward = backdropFBM(at - float2(0.0, 0.07));
    const float facing = clamp((density - toward) * 5.0 + 0.45, 0.0, 1.0);
    const float rim = 1.0 - smoothstep(threshold, threshold + 0.22, density);
    const float fromBelow = mix(1.0, 0.3, smoothstep(0.0, 0.85, h));
    const float3 tint = backdropWalk(colors, clamp(1.0 - h * 0.95 + warp.x * 0.5, 0.0, 1.0));
    const float3 shade = backdropLuminanceOnly(tint, 0.7) * mix(0.14, 0.26, fromBelow);
    const float3 lit = mix(tint, float3(1.0), 0.18) * mix(0.45, 1.0, fromBelow);
    float3 cloudColor = mix(shade, lit, facing * (0.4 + 0.6 * fromBelow));
    cloudColor += tint * rim * 0.22 * fromBelow;
    color = mix(color, cloudColor, cloud * strengths[layer]);
  }

  return color;
}
// MARK: - Space

/// One depth of stars: a star in some cells of a grid, drifting left at
/// `drift` points a second, each twinkling on its own clock.
static float3 backdropStarLayer(
  float2 local, float cellSize, float chance, float radius, float drift, float seed,
  float t, float pixel, constant float4 *colors
) {
  const float2 at = local + float2(t * drift, 0.0);
  const float2 cell = floor(at / cellSize);
  const float pick = backdropHash(cell + seed);
  if (pick > chance) { return float3(0.0); }
  const float2 jitter = float2(backdropHash(cell + seed + 3.1), backdropHash(cell + seed + 7.7));
  const float2 centre = (cell + 0.15 + 0.7 * jitter) * cellSize;
  const float size = radius * (0.6 + 0.8 * backdropHash(cell + seed + 1.9));
  const float distance = length(at - centre);
  const float core = smoothstep(size + pixel, max(size - pixel, 0.0), distance);
  const float halo = exp(-distance / (size * 3.5)) * 0.25 * step(0.7, pick / chance);
  const float twinkle = 0.6 + 0.4 * sin(t * (0.7 + jitter.x * 1.8) + jitter.y * 40.0);
  const float3 tint = mix(float3(1.0), backdropWalk(colors, jitter.x), 0.35);
  return tint * (core + halo) * twinkle;
}

static float3 backdropSpace(float2 local, float2 size, float t, float pixel, constant float4 *colors) {
  const float h = local.y / size.y;
  float3 color = mix(backdropWalk(colors, 0.85) * 0.07, colors[0].rgb * 0.025, smoothstep(0.0, 0.9, h));

  // A nebula across the lower half, turning very slowly through the face's
  // colours: two warped clouds, the second a thin bright filament.
  //
  // The costly part of every scene (≈ 2.4 ms a Retina frame on an M1 Pro
  // when every pixel paid for 25 octaves), so each noise is asked only where
  // it can show: none outside the nebula's lane, the filament only inside
  // the cloud, the dust only where there is cloud to darken — and with as few
  // octaves as its shape needs.
  const float lane = exp(-pow((h - 0.34 - (local.x / size.x - 0.5) * 0.4) / 0.34, 2.0));
  if (lane > 0.02) {
    const float2 uv = local / 300.0 + float2(t * 0.004, t * 0.002);
    const float2 warp = float2(backdropFBM(uv * 0.8, 3), backdropFBM(uv * 0.8 + float2(3.7, 8.1), 3)) - 0.5;
    const float body = backdropFBM(uv * 1.1 + 1.4 * warp, 5);
    const float cloud = smoothstep(0.34, 0.78, body) * lane;
    const float inside = smoothstep(0.35, 0.7, body);
    if (cloud > 0.002 || inside > 0.0) {
      const float3 tint = backdropWalk(colors, clamp(body * 1.4 - 0.2 + warp.y, 0.0, 1.0));
      float filament = 0.0;
      if (inside > 0.0) {
        const float strand = backdropFBM(uv * 2.3 - 2.0 * warp + float2(t * 0.006, 0.0), 4);
        filament = pow(1.0 - abs(strand - 0.5) * 2.0, 6.0) * lane * inside;
      }
      color += tint * cloud * 0.8 + mix(tint, float3(1.0), 0.3) * filament * 0.4;
      // Dark lanes of dust across the bright part, as a nebula has.
      color *= 1.0 - smoothstep(0.55, 0.75, backdropFBM(uv * 3.0 + warp * 2.0, 3)) * 0.45 * lane;
    }
  }

  // Three depths of stars; the nearest drift fastest.
  color += backdropStarLayer(local, 14.0, 0.10, 0.45, 0.6, 0.0, t, pixel, colors) * 0.45;
  color += backdropStarLayer(local, 26.0, 0.07, 0.75, 1.4, 17.0, t, pixel, colors) * 0.7;
  color += backdropStarLayer(local, 48.0, 0.05, 1.1, 2.6, 41.0, t, pixel, colors);

  // Now and then a star falls across the upper sky.
  const float period = 9.0;
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
    color += mix(float3(1.0), backdropWalk(colors, 0.2), 0.3) * streak * fade * 0.8;
  }
  return color;
}

// MARK: - Matrix

/// The six mascot outlines (`MascotShape`) as signed distances in a unit
/// cell, y up: Blossom, Hotdog, Spotty, Boltty, Pampuh, Onigiri.
static inline float backdropMascotShape(float2 p, int shape) {
  const float angle = atan2(p.y, p.x);
  switch (shape) {
  case 0: // Blossom: six round petals.
    return length(p) - (0.78 + 0.16 * cos(6.0 * angle + 1.5708));
  case 1: { // Hotdog: a wide pill.
    const float2 q = abs(p) - float2(0.38, 0.0);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.6;
  }
  case 2: // Spotty: eight shallow petals.
    return length(p) - (0.84 + 0.09 * cos(8.0 * angle));
  case 3: { // Boltty: a rounded hexagon.
    const float3 k = float3(-0.866025, 0.5, 0.577350);
    float2 q = abs(p.yx);
    q -= 2.0 * min(dot(k.xy, q), 0.0) * k.xy;
    q -= float2(clamp(q.x, -k.z * 0.72, k.z * 0.72), 0.72);
    return length(q) * sign(q.y) - 0.2;
  }
  case 4: // Pampuh: a ball.
    return length(p) - 0.9;
  default: { // Onigiri: a rounded triangle, point up.
    const float k = 1.732051;
    float2 q = float2(abs(p.x) - 0.62, p.y + 0.3);
    if (q.x + k * q.y > 0.0) { q = float2(q.x - k * q.y, -k * q.x - q.y) / 2.0; }
    q.x -= clamp(q.x, -1.24, 0.0);
    return -length(q) * sign(q.y) - 0.22;
  }
  }
}

/// One depth of falling mascot silhouettes, plain: no eyes or smile. Each
/// column has its own speed and trail; each cell wears one of the outlines,
/// and now and then swaps it for another.
static float3 backdropRain(
  float2 local, float2 size, float2 cell, float seed, float t, float pixel, constant float4 *colors
) {
  // Rows count down from the top, as the rain falls.
  const float2 fromTop = float2(local.x, size.y - local.y);
  const float column = floor(fromTop.x / cell.x);
  const float row = floor(fromTop.y / cell.y);
  const float speed = 5.0 + 10.0 * backdropHash(float2(column, seed));
  const float trail = 12.0 + 28.0 * backdropHash(float2(column, seed + 1.0));
  const float period = trail + 12.0 + 48.0 * backdropHash(float2(column, seed + 2.0));
  const float headRow = t * speed + period * backdropHash(float2(column, seed + 3.0));
  const float behind = headRow - row;
  const float d = behind - floor(behind / period) * period;
  const bool lit = d < trail;
  const float fade = lit ? pow(1.0 - d / trail, 1.6) : 0.012;

  // Which outline: some cells change often, most rarely.
  const float churn = backdropHash(float2(column, row) + seed + 5.0) > 0.85 ? 3.0 : 0.3;
  const float glyph = floor(t * churn + backdropHash(float2(column, row) + seed) * 10.0);
  const int shape = int(backdropHash(float2(glyph, column + row * 7.0 + seed)) * 5.999);

  // The outline in a unit square, y up, a little smaller than its cell.
  const float unit = min(cell.x, cell.y) * 0.4;
  float2 p = (fromTop - (float2(column, row) + 0.5) * cell) / unit;
  p.y = -p.y;
  const float aa = pixel / unit;
  const float body = smoothstep(aa, -aa, backdropMascotShape(p, shape));
  if (body <= 0.0) { return float3(0.0); }

  const float on = body;

  // A pale face (Citrus, Daybreak) would rain twice as bright as a deep one
  // and drown the answer's white prose; every colour is brought to one
  // lightness, so each agent's rain is its hue at the same quiet level.
  const float3 trailColor = backdropAtLightness(backdropWalk(colors, 0.15 + 0.7 * clamp(d / trail, 0.0, 1.0)), 0.32);
  const float3 headColor = backdropAtLightness(mix(colors[2].rgb, float3(1.0), 0.4), 0.6);
  const float3 tint = (lit && d < 1.0) ? headColor : trailColor;
  return tint * on * fade;
}

static float3 backdropMatrix(float2 local, float2 size, float t, float pixel, constant float4 *colors) {
  const float h = local.y / size.y;
  float3 color = mix(backdropWalk(colors, 0.6) * 0.05, float3(0.0), smoothstep(0.0, 1.0, h));
  // A far layer, small and dim, then the near one.
  color += backdropRain(local, size, float2(5.0, 5.0), 31.0, t * 0.7, pixel, colors) * 0.3;
  color += backdropRain(local, size, float2(8.5, 8.5), 0.0, t, pixel, colors) * 0.75;
  return color;
}

// MARK: - The frame

fragment float4 agentBackdropFragment(
  BackdropVaryings in [[stage_in]],
  constant AgentBackdropUniforms &u [[buffer(AgentBackdropBufferIndexUniforms)]]
) {
  if (u.opacity <= 0.0) { return float4(0.0); }
  const float2 size = max(u.size, float2(1.0));
  const float h = in.local.y / size.y;
  const float t = u.clock;

  float3 color;
  if (u.scene > 2.5) {
    color = backdropMatrix(in.local, size, t, u.pixelSize, u.colors);
  } else if (u.scene > 1.5) {
    color = backdropSpace(in.local, size, t, u.pixelSize, u.colors);
  } else {
    color = backdropSky(in.local, size, t, u.colors);
  }

  // The top darkens toward black, as the shell's ramp does elsewhere.
  color *= mix(1.0, 0.45, smoothstep(0.62, 1.0, h));
  // Sub-quantum grain against banding in a wash this smooth.
  color += (backdropHash(in.position.xy + fract(t)) - 0.5) / 255.0;

  return float4(max(color, 0.0) * u.opacity, u.opacity);
}
