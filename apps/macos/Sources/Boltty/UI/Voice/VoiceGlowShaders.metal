//  VoiceGlowShaders.metal
//
//  The Boltty AI voice glow: rays of the mascot's colours fanning out of one
//  point, drawn **under the shell's glass** so the glass bends and frosts them
//  as they move — and, while listening, an orb: the shell gone round and
//  filled with one soft, saturated gradient of the face's colours, drawn under
//  the glass and again **on** it by a second view (`layer` 1), since the glass
//  greys whatever is under it.
//
//  A burst of coloured rays that keep sliding through one another: the
//  colour of a ray is a value noise of
//  its angle, so wedges of the palette lie side by side, and the same noise
//  also drifts along the radius, so each wedge streams outward from the origin
//  as if the picture were being flown through. Three octaves turn at different
//  rates in different directions, which is what makes the rays pass through one
//  another rather than rotate as a disc. The orb is after Siri's ball and
//  tiles of mesh gradients; see the orb's own section below.
//
//  What the voice does is **move it**: the CPU integrates a speed that follows
//  the level into `flow`, so a loud syllable quickens the rays and the picture
//  does not lurch (see `VoiceGlowUniforms.flow`).
//
//  Under the glass this is a picture the glass looks through, drawn
//  premultiplied; on it, the orb's surface is light added over a veil.

#include <metal_stdlib>
#include "VoiceGlowUniforms.h"

using namespace metal;

struct Varyings {
  float4 position [[position]];
  /// Points from the shell's bottom-left corner. Unflipped, matching
  /// `VoiceEdgeGlowLayout`, where y = 0 is the bottom edge.
  float2 local;
};

/// One triangle covering the viewport, with no vertex buffer.
///
/// A triangle rather than two — a quad's shared diagonal makes the GPU shade
/// the pixels along it twice, and there is no clipping cost to the overhang.
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

/// Signed distance to the shell's rounded rectangle.
///
/// The exponent is the point. `NSGlassEffectView` draws a *continuous* corner,
/// and `PaletteGlassHost.applyContinuousCorner` records what happens when
/// something nearby assumes a circular one — the two "part company along the
/// wall by more than a glyph is wide". A circular clip here would let the glow
/// show past the glass's own corner. An L^3.6 norm tracks the squircle closely
/// enough that the remaining error is under a point.
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

/// Sub-quantum noise, to break up 8-bit steps.
///
/// ±0.5/255, applied last: below the threshold of grain and exactly enough to
/// scatter a quantisation edge. A wash this smooth is where banding shows.
static inline float ditherNoise(float2 p) {
  return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
}

/// A random value for an integer lattice point.
static inline float lattice(float2 cell) {
  float2 p = fract(cell * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

/// Value noise that is **periodic in x** and free in y.
///
/// x is an angle measured in cells, `period` of them to the turn: the lattice
/// wraps, so the picture has no seam where the angle jumps from +π to −π, and
/// shifting x by any amount just turns the rays. y is the radius, in cells,
/// and is what carries a wedge outward.
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

  // Quintic, so a ray's edge leaves with no visible slope change.
  const float sx = fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0);
  const float sy = fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0);
  return mix(mix(a, b, sx), mix(c, d, sx), sy);
}

/// A walk along the mascot's stops, top of its body to the foot.
///
/// `v` runs 0…1 over the whole palette. It is never wrapped: a face like
/// Daybreak has blue at one end and amber at the other, and a ray that ran off
/// the end and came back at the start would jump between them.
static inline float3 ringColor(constant VoiceGlowUniforms &u, float v) {
  const float pos = saturate(v) * float(VOICE_GLOW_COLOR_COUNT - 1);
  const int i = min(int(floor(pos)), VOICE_GLOW_COLOR_COUNT - 2);
  const float f = smoothstep(0.0, 1.0, pos - float(i));
  return mix(u.colors[i].rgb, u.colors[i + 1].rgb, f);
}

static inline float3 paletteLight(constant VoiceGlowUniforms &u, float n, float level, float carry);

/// The palette's light at one point: the rays, their window on the palette,
/// pushed away from grey. `turnPhase` and `rho` are the point's angle (in
/// turns) and distance about the rays' origin.
static inline float3 rayColour(
  constant VoiceGlowUniforms &u, float turnPhase, float rho, float level, thread float &n1
) {
  // Processing winds the rays into a spiral, tighter the further out, and the
  // steady `flow` then turns it.
  const float wind = u.beam * 1.9 * log2(1.0 + rho * 1.6) * (1.0 / 6.2831853);
  const float a = turnPhase + wind;

  // Three octaves of rays, turning against one another and each streaming
  // outward at its own rate. The radial scale is long, so a wedge is a streak,
  // not a blob.
  const float f = u.flow;
  n1 = rayNoise(a * 7.0 + f * 0.50, 7.0, rho * 0.80 - f * 0.20, 1.0);
  const float n2 = rayNoise(a * 13.0 - f * 0.78, 13.0, rho * 1.15 - f * 0.34, 17.0);
  const float n3 = rayNoise(a * 22.0 + f * 1.25, 22.0, rho * 1.90 - f * 0.55, 31.0);

  // Averaging three noises piles the values up in the middle, which would draw
  // every ray the same mid-palette colour. Stretched about the middle, so the
  // rays reach both ends of what they are given — more so the louder it is.
  const float gain = 2.0 + 1.6 * level;
  const float n = saturate((n1 * 0.52 + n2 * 0.31 + n3 * (0.17 + 0.10 * level) - 0.5) * gain + 0.5);

  // The rays are given a **window** of the palette, not all of it, and the
  // window wanders. The glass blurs what it covers, and two rays of
  // complementary colours side by side — Daybreak's blue against its amber —
  // blur to the grey between them; neighbours a few stops apart blur to a
  // colour. So at rest the shell is lit by a few stops at a time and the
  // window sweeps the whole palette over seconds; the voice widens it, so a
  // loud word shows the whole palette at once.
  // Near-whites are carried to the body colour only where words may stand on
  // the light — not in the orb, whose band is meant to burn white.
  return paletteLight(u, n, level, 0.8 * (1.0 - u.orb));
}

/// A noise value 0…1 turned into the palette's light: the wandering window on
/// the palette, pushed away from grey, and `carry` of its near-whites carried
/// to the body colour.
static inline float3 paletteLight(constant VoiceGlowUniforms &u, float n, float level, float carry) {
  const float f = u.flow;
  const float span = mix(0.46, 1.0, level);
  const float centre = 0.5 + 0.30 * sin(f * 0.23 + 1.0) + 0.14 * sin(f * 0.57 + 4.0);
  float3 colour = ringColor(u, saturate(centre + (n - 0.5) * span));

  // The glass dims and frosts whatever is under it, so the picture is pushed
  // further than it would be to be seen on its own.
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

// MARK: - The orb
//
// Dark, with the face's colours running through it in waves, in the shape of
// the shell. Nothing in it has an edge or a line but the shell's own. No
// grain: a visible one was tried, and the gradient reads cleaner without it.
//
// **Silence is near black; the voice lights the edge.** At rest a faint rim and
// the dim crests of slow waves. A word fills the rim unevenly, in waves that
// run round it, quickens everything (`flow`), and sends ripples in from the
// edge that die before the middle (`voice`, a quick envelope). The middle
// stays calm.
//
// **It is drawn on top of the panel's glass** (`layer` 1), opaque to a crisp
// edge, and the system glass under it does not show: under the glass it
// comes out frosted, its rim a soft halo. The layer
// under the glass draws the same picture, for the moment the shell is still
// turning into the orb.

/// Pushed away from grey by `amount` (1 leaves it).
static inline float3 vivid(float3 c, float amount) {
  const float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
  return saturate(mix(float3(luma), c, amount));
}

/// A walk along the face's stops, 0…1 top of its body to the foot, straight
/// between neighbours: the field it is handed is smooth, so the colour is.
static inline float3 orbWalk(constant VoiceGlowUniforms &u, float v) {
  const float pos = saturate(v) * float(VOICE_GLOW_COLOR_COUNT - 1);
  const int i = min(int(floor(pos)), VOICE_GLOW_COLOR_COUNT - 2);
  return mix(u.colors[i].rgb, u.colors[i + 1].rgb, pos - float(i));
}

/// The two colours the orb is made of: the face's most saturated stop, and
/// the stop that is most saturated *and* furthest from it. Never a pale stop —
/// a gradient of Daybreak's pale band and Candy's pale pink came out a cream
/// ball, where the reference's tiles are deep, saturated colour.
static inline void orbColours(constant VoiceGlowUniforms &u, thread float3 &ground, thread float3 &second) {
  int g = 0;
  float best = -1.0;
  for (int i = 0; i < VOICE_GLOW_COLOR_COUNT; ++i) {
    const float3 c = u.colors[i].rgb;
    const float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    if (chroma > best) { best = chroma; g = i; }
  }
  ground = u.colors[g].rgb;
  int k = g == 0 ? 1 : 0;
  float bestScore = -1.0;
  for (int i = 0; i < VOICE_GLOW_COLOR_COUNT; ++i) {
    if (i == g) { continue; }
    const float3 c = u.colors[i].rgb;
    const float chroma = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    const float score = chroma * (0.25 + length(c - ground));
    if (score > bestScore) { bestScore = score; k = i; }
  }
  second = u.colors[k].rgb;
}

/// The orb's geometry, for the ball and for the capsule it grows into round
/// the words being said: `R` is half the shell's short side, and the *spine*
/// is the segment its round ends are centred on — a point for the ball.
struct OrbShape {
  /// From the spine, in the ball's unit: 0 on the spine, 1 at the rim.
  float2 q;
  /// The point as the pools see it: the ball's unit, a long shell widening
  /// them by the square root of its length, not in proportion.
  float2 g;
  /// How far `g` runs from the middle to each end: 1 for the ball.
  float2 span;
};

static inline OrbShape orbShape(float2 p, float2 halfSize) {
  OrbShape o;
  const float R = max(min(halfSize.x, halfSize.y), 1.0);
  const float2 c = p - halfSize;
  const float2 spine = max(halfSize - R, 0.0);
  o.q = (c - clamp(c, -spine, spine)) / R;
  const float len = max(halfSize.x, halfSize.y) / R;
  const float2 axis = halfSize.x >= halfSize.y ? float2(sqrt(len), 1.0) : float2(1.0, sqrt(len));
  o.g = c / (R * axis);
  o.span = halfSize / (R * axis);
  return o;
}

/// The gradient at a point of the shell (y up).
static inline float3 orbGradient(constant VoiceGlowUniforms &u, OrbShape o, float level) {
  const float f = u.flow;
  const float voice = saturate(u.voice);
  const float lift = saturate(0.45 * level + 1.10 * voice);
  const float2 g = o.g;

  float3 ground;
  float3 second;
  orbColours(u, ground, second);
  ground = vivid(ground, 1.35);
  second = vivid(second, 1.35);

  // Where a point is: how far round the shape's edge, in turns, and how far
  // in from it — 0 on the edge, 1 on the middle (the capsule's spine).
  const float2 across = g / max(o.span, float2(0.001));
  const float around = atan2(across.y, across.x) * (1.0 / 6.2831853);
  const float r = min(length(o.q), 1.0);
  const float inward = 1.0 - r;
  // How much "round the edge" still means anything: every angle meets in the
  // middle, and a pattern that follows the angle there is a pinwheel.
  const float rimward = 1.0 - smoothstep(0.25, 0.85, inward);

  // The field the colour runs through, swirled twice so a band bends and folds
  // as it travels instead of sliding past as a stripe.
  float2 w = g;
  w += 0.40 * float2(sin(1.9 * g.y + 0.80 * f), cos(1.7 * g.x - 0.65 * f));
  w += 0.20 * float2(sin(3.1 * w.y - 1.20 * f + 1.7), cos(2.7 * w.x + 1.05 * f + 0.4));

  // The colour walks the face's own gradient, so blue meets amber through the
  // stops between them, as on the face, not as two patches side by side; and
  // round the edge the walk turns slowly, so the rim wears the whole gradient.
  const float shade = 0.5 + 0.30 * sin(1.6 * w.x + 1.1 * w.y - 0.90 * f)
    + 0.18 * sin(6.2831853 * around + 0.40 * f) * rimward;
  float3 colour = vivid(orbWalk(u, shade), 1.30);

  // The middle is calm: only the crests of slow waves, dim, and dimmer toward
  // the middle. The light lives at the edge.
  const float lit = sqrt(lift);
  const float run = 0.5 + 0.5 * sin(2.2 * w.x + 1.3 * w.y - 1.50 * f);
  const float body = pow(run, mix(3.2, 1.6, lit)) * (0.06 + 0.32 * lit) * (0.35 + 0.65 * r);

  // The edge fills with the voice, unevenly: how far in its light reaches
  // swells and falls in waves that run round the rim, two and three to a turn.
  const float swell = 0.5 + (0.25 * sin(6.2831853 * 2.0 * around - 1.30 * f)
    + 0.25 * sin(6.2831853 * 3.0 * around + 0.90 * f + 1.3)) * rimward;
  const float depth = 0.05 + lit * (0.08 + 0.34 * swell);
  const float edge = exp(-inward / depth);

  // And the voice's echo runs in from the edge, gone before the middle.
  const float echo = pow(0.5 + 0.5 * sin(14.0 * inward + 3.0 * f + 2.0 * rimward * sin(6.2831853 * around + 0.5 * f)), 2.0)
    * exp(-4.0 * inward) * voice;

  colour *= body + edge * (0.22 + 0.95 * lit) + echo * 0.35;

  // Saturated the more is said.
  colour = vivid(colour, 1.20 + 0.35 * lift);

  // Grown round the words, the middle goes deep — leaning to the second
  // colour, since a yellow only darkened is olive — for white words to stand
  // on, and the light keeps to the rim and the round ends. The ball has no
  // words, and none of this.
  const float worded = smoothstep(1.02, 1.30, max(o.span.x, o.span.y));
  const float smoke = (1.0 - smoothstep(0.30, 0.95, r)) * worded;
  const float3 deep = vivid(mix(colour, second, 0.45), 1.30) * (0.42 + 0.10 * lift);
  colour = mix(colour, deep, smoke);
  return saturate(colour) * mix(1.0, 0.85, u.appearance);
}

fragment float4 voiceGlowFragment(
  Varyings in [[stage_in]],
  constant VoiceGlowUniforms &u [[buffer(VoiceGlowBufferIndexUniforms)]]
) {
  const float2 p = in.local;
  const float2 halfSize = u.size * 0.5;
  const float distance = shellDistance(p - halfSize, halfSize, u.cornerRadius, u.cornerIsContinuous);
  const float aa = max(u.pixelSize, 0.25);
  const bool fills = u.orb > 0.0;
  const float level = saturate(u.intensity);
  const float grain = ditherNoise(in.position.xy) * (1.0 / 255.0);

  if (u.layer > 0.5) {
    // On the glass: the orb, whole and opaque, to the shell's own edge — the
    // glass under it does not show, so nothing frosts it.
    const float edge = 1.0 - smoothstep(-aa, 0.0, distance);
    const float strength = u.orb * u.opacity * edge;
    if (!fills || strength <= 0.0) { return float4(0.0); }
    const float3 colour = orbGradient(u, orbShape(p, halfSize), level);
    return float4(saturate(colour + grain) * strength, strength);
  }

  // Under the glass. Clipped a point inside its edge, so no fringe of colour
  // shows outside the rim the glass draws over it.
  const float clip = 1.0 - smoothstep(-aa, 0.0, distance + 1.0);
  if (clip <= 0.0 || u.opacity <= 0.0 || (!fills && p.y >= u.reach * 1.45)) {
    return float4(0.0);
  }

  // The rays across the shell, or the orb filling it.

  // Polar, around the origin, in true geometry: the capsule is wide and short,
  // and an angle measured in a stretched space would bend every ray.
  const float2 d = p - u.origin;
  const float unit = max(u.size.y, 32.0);
  const float rho = length(d) / unit;
  float n1 = 0.0;
  float3 colour = rayColour(u, atan2(d.y, d.x) * (1.0 / 6.2831853), rho, level, n1);

  // Light travelling out along the rays, quicker and deeper with the voice.
  const float ripple = sin(rho * 6.5 - u.flow * 3.2 + n1 * 6.2831853);
  const float lit = 0.90 + 0.10 * ripple * (0.35 + 0.65 * level);

  // Hot where the rays start, and a little darker toward the crown, where the
  // words stand in a box.
  const float core = exp(-rho * 1.5);
  colour = mix(colour, float3(1.0), core * (0.14 + 0.26 * level));
  const float crown = mix(1.0, 0.80, smoothstep(0.30, 1.0, p.y / max(u.size.y, 1.0)));

  const float exposure = mix(1.0, 0.82, u.appearance);
  colour *= lit * crown * exposure * (0.90 + 0.10 * level);

  // A taller shell is lit from its foot only, and the light dissolves above.
  const float foot = 1.0 - smoothstep(u.reach, u.reach * 1.45, p.y);

  float4 picture = float4(colour, 1.0) * foot;
  if (fills) {
    picture = mix(picture, float4(orbGradient(u, orbShape(p, halfSize), level), 1.0), u.orb);
  }

  // Premultiplied: this is a picture the glass looks through. Not quite opaque
  // — the glass's own depth shows at the very edge — and fading with the phase.
  const float coverage = clip * u.opacity * 0.96;
  picture *= coverage;
  return float4(saturate(picture.rgb + grain * picture.a), saturate(picture.a));
}
