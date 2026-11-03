//  AgentBackdropShaders.metal
//
//  What an open chat wears behind its transcript, in the agent's own
//  sky (`ChatBackdrop`, `AgentBackdropSky`): clouds, or stars on near black.
//
//  The sky is after Messages' Sky backgrounds, read off the system's
//  `DynamicBackgroundPosterExtension` (`clouds.vfx`): there each cloud is a
//  large sprite cut from a packed cloud texture, its UVs pushed about by two
//  scrolling noise samples, its edge choked with a `smoothstep`, and tinted by
//  a vertical ramp; three depths (far, middle, near) drift at their own
//  speeds, and a preset is only another row of the ramps. Here the sprite is
//  replaced by domain-warped noise, so nothing of theirs ships and the shapes
//  never repeat; the preset is the face's own sky (`AgentBackdropSky`): a
//  blue face gets a blue day, a pink-and-cyan one a teal dusk with rosy
//  clouds. The sky is whole and coloured, as theirs is, but deeper, and its
//  brightness rolls off under a ceiling: theirs carries bubbles, ours carries
//  bare white prose.
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

/// Brightness rolled off above `knee` so it never passes `ceiling`, hue kept:
/// white prose stays readable on the brightest cloud, and a pale face's sky
/// keeps its colour instead of clipping to white.
static inline float3 backdropCeiling(float3 c, float knee, float ceiling) {
  const float y = dot(c, float3(0.2126, 0.7152, 0.0722));
  if (y <= knee) { return c; }
  const float room = ceiling - knee;
  return c * ((knee + room * (1.0 - exp(-(y - knee) / room))) / y);
}

// MARK: - Sky

static float3 backdropSky(float2 local, float2 size, float t, constant float4 *sky) {
  // Height 0 at the foot, 1 at the top; uv square, so clouds keep their shape
  // as the chat is resized.
  const float h = local.y / size.y;
  const float2 uv = local / 420.0;
  const float3 zenith = sky[0].rgb;
  const float3 horizon = sky[1].rgb;
  const float3 sunlight = sky[2].rgb;
  const float3 underside = sky[3].rgb;
  const float3 middle = sky[4].rgb;
  const float3 glow = sky[5].rgb;

  // The feeling of the face's colour, not a wall of it: a soft walk from the
  // horizon through the middle of the sky to the zenith, leaning across the
  // chat and breathing with a slow noise, so no two heights are one flat
  // band. The sun's glow warms one corner low down.
  const float x = local.x / size.x;
  const float lean = (backdropFBM(local / size * 1.3 + float2(t * 0.006, 0.0), 3) - 0.5) * 0.3;
  const float g = clamp(h * 0.85 + (0.5 - x) * 0.25 + lean, 0.0, 1.0);
  float3 color = mix(horizon, middle, smoothstep(0.0, 0.5, g));
  color = mix(color, zenith, smoothstep(0.42, 0.95, g));
  const float2 sunAt = float2(size.x * 0.78, -size.y * 0.06);
  const float sun = exp(-pow(length((local - sunAt) / float2(size.x * 0.75, size.y * 0.5)), 1.4) * 1.8);
  color = mix(color, glow, sun * 0.75);

  // Far, middle and near: each larger, faster and lower than the last — the
  // same three depths as Messages' BG, MG and FG. The far ones sit in the
  // sky's own haze.
  const float3 scales = float3(2.1, 1.4, 0.95);
  const float3 speeds = float3(0.0125, 0.023, 0.036);
  const float3 bands = float3(0.7, 0.45, 0.18);
  const float3 haze = float3(0.45, 0.2, 0.0);
  const float3 softness = float3(0.2, 0.13, 0.09);

  for (int layer = 0; layer < 3; layer++) {
    // Wider than tall, as clouds lie in a sky.
    const float2 p = float2(uv.x * 0.5, uv.y) * scales[layer]
      + float2(t * speeds[layer], 0.0) + float2(float(layer) * 11.7, float(layer) * 3.9);
    // Two slow noises push the shape about, as Messages' two scrolling
    // samples push its sprite's UVs, so the clouds billow as they drift.
    const float2 warp = float2(
      backdropFBM(p * 0.55 + float2(0.0, t * 0.02), 3),
      backdropFBM(p * 0.55 + float2(5.2, 1.3) - t * 0.016, 3)
    ) - 0.5;
    const float2 at = p + 0.6 * warp;
    // Four octaves: a fifth frays the edges into smoke.
    const float density = backdropFBM(at, 4);
    // A band of weather per layer, so the sky is not covered evenly.
    const float band = exp(-pow((h - bands[layer]) / 0.22, 2.0));
    const float threshold = mix(0.6, 0.36, band);
    // The choke: a soft edge, not a fog; softer far away.
    const float cloud = smoothstep(threshold, threshold + softness[layer], density);
    if (cloud <= 0.001) { continue; }

    // Lit from above: where the cloud thins toward the light it is bright,
    // where it thickens away from it, the underside takes the shade.
    const float toward = backdropFBM(at + float2(0.05, 0.16), 4);
    const float lit = clamp((density - toward) * 5.0 + 0.4, 0.0, 1.0);
    const float thick = smoothstep(threshold + 0.04, threshold + 0.32, density);
    // The shade is the sky's own colour gone deeper, so a cloud belongs to
    // the sky it sits in; the light is the sun's, warmed by its glow.
    const float3 shade = mix(underside, color * 0.8, 0.45);
    const float3 light = mix(sunlight, glow, sun * 0.35);
    float3 body = mix(shade, light, lit * mix(1.0, 0.6, thick));
    // A silver lining where the cloud is thin and faces the light.
    body += light * (1.0 - thick) * lit * 0.3;
    // Aerial perspective: far clouds melt into the sky behind them.
    body = mix(body, color, haze[layer]);
    color = mix(color, body, cloud);
  }

  return backdropCeiling(color, 0.28, 0.52);
}

// MARK: - Space

/// One depth of stars: a star in some cells of a grid, drifting left at
/// `drift` points a second, each twinkling on its own clock.
static float backdropStarLayer(
  float2 local, float cellSize, float chance, float radius, float drift, float seed,
  float t, float pixel
) {
  const float2 at = local + float2(t * drift, 0.0);
  const float2 cell = floor(at / cellSize);
  const float pick = backdropHash(cell + seed);
  if (pick > chance) { return 0.0; }
  const float2 jitter = float2(backdropHash(cell + seed + 3.1), backdropHash(cell + seed + 7.7));
  const float2 centre = (cell + 0.15 + 0.7 * jitter) * cellSize;
  const float size = radius * (0.6 + 0.8 * backdropHash(cell + seed + 1.9));
  const float distance = length(at - centre);
  const float core = smoothstep(size + pixel, max(size - pixel, 0.0), distance);
  const float halo = exp(-distance / (size * 3.5)) * 0.25 * step(0.7, pick / chance);
  const float twinkle = 0.6 + 0.4 * sin(t * (0.7 + jitter.x * 1.8) + jitter.y * 40.0);
  return (core + halo) * twinkle;
}

static float3 backdropSpace(float2 local, float2 size, float t, float pixel, constant float4 *sky) {
  const float h = local.y / size.y;
  const float3 zenith = sky[0].rgb;
  const float3 horizon = sky[1].rgb;
  const float3 light = sky[2].rgb;

  // Near black, as space is, with a breath of the face's sky low down.
  float3 color = mix(horizon * 0.1, zenith * 0.05, smoothstep(0.0, 0.85, h));

  // Three depths of stars, white with a breath of the face's light; the
  // nearest drift fastest.
  const float3 starTint = mix(float3(1.0), light, 0.25);
  float stars = backdropStarLayer(local, 8.0, 0.07, 0.45, 0.8, 0.0, t, pixel) * 0.6;
  stars += backdropStarLayer(local, 20.0, 0.1, 0.75, 1.6, 17.0, t, pixel) * 0.85;
  stars += backdropStarLayer(local, 46.0, 0.06, 1.05, 2.8, 41.0, t, pixel);
  // Fewer stars low down, in the dusk's glow.
  color += starTint * stars * smoothstep(0.0, 0.35, h);

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
    color += starTint * streak * fade * 0.8;
  }
  return backdropCeiling(color, 0.24, 0.46);
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
  if (u.scene > 1.5) {
    color = backdropSpace(in.local, size, t, u.pixelSize, u.sky);
  } else {
    color = backdropSky(in.local, size, t, u.sky);
  }

  // The top darkens toward black, as the shell's ramp does elsewhere.
  color *= mix(1.0, 0.45, smoothstep(0.62, 1.0, h));
  // Sub-quantum grain against banding in a wash this smooth.
  color += (backdropHash(in.position.xy + fract(t)) - 0.5) / 255.0;

  return float4(max(color, 0.0) * u.opacity, u.opacity);
}
