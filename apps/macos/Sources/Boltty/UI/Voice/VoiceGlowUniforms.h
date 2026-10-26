//  VoiceGlowUniforms.h
//
//  One definition of the renderer's per-frame state, compiled twice: once by
//  Swift through `Boltty-Bridging-Header.h`, and once by the Metal compiler
//  from `VoiceGlowShaders.metal`.
//
//  Written once rather than twice because the failure mode of two declarations
//  is silent. A field added on one side only does not fail to build — it
//  shifts every field after it by its own size, and the picture that comes back
//  is wrong in a way that looks like a bad shader rather than a bad struct.

#ifndef VoiceGlowUniforms_h
#define VoiceGlowUniforms_h

#include <simd/simd.h>

/// The mascot's six stops, top of its body to the foot. The rays take their
/// colour from a walk along them, so a face in lime and turquoise lights the
/// shell in lime and turquoise.
#define VOICE_GLOW_COLOR_COUNT 6

/// Buffer indices, so neither side names a slot the other does not.
typedef enum {
  VoiceGlowBufferIndexUniforms = 0
} VoiceGlowBufferIndex;

typedef struct {
  /// Shell size in points. The shader works in points, never pixels, so the
  /// picture is identical on a 1x display and a 2x one.
  simd_float2 size;
  /// Points per pixel. Used for one thing: the width of an antialiased edge.
  float pixelSize;

  /// Corner of the shell this is clipped to, from `PaletteGlassHost`'s
  /// *rendered* corner rather than its requested one.
  float cornerRadius;
  /// 1 when the glass drew a squircle, 0 when it drew a circular corner.
  float cornerIsContinuous;

  /// 0…1, the voice. Drives how hard the rays are lit and how far they run.
  float intensity;
  /// 0 = listening, the rays fanning out; 1 = processing, the rays winding
  /// into a spiral that turns steadily.
  float beam;
  /// Overall opacity, including the phase fade.
  float opacity;
  /// 0 = dark appearance, 1 = light.
  float appearance;
  /// Seconds since the phase began. Drives what moves independently of the
  /// voice. Frozen at 0 under Reduce Motion.
  float clock;
  /// How far the rays have travelled. **The integral of a speed that follows
  /// the voice**, kept on the CPU: the shader reading `clock * speed` would
  /// jump whenever the speed changed, and the picture would lurch on every
  /// syllable instead of quickening. Frozen at 0 under Reduce Motion.
  float flow;

  /// How far up from the bottom edge the light reaches, in points. The whole
  /// height for the listening capsule; in a taller shell it stops short, so an
  /// open chat is lit at its foot and not through its transcript.
  float reach;

  /// 0 = the rays, 1 = the orb's gradient filling the shell — the listening
  /// orb, and the capsule it grows into round the words being said. Set by
  /// the panel when a take collapses the shell, not read off its proportions:
  /// that capsule is as long as the prompt it came from.
  float orb;
  /// Which of the two views this frame is for: 0 = the light *under* the
  /// glass, which the glass frosts and bends; 1 = the orb *on* the glass,
  /// opaque to the shell's edge, which the system glass would have greyed and
  /// blurred.
  float layer;
  /// 0…1, the voice as it is *now*: the same reading as `intensity`, through a
  /// quick envelope instead of a slow one, so the orb's pools can swell on a
  /// syllable and settle in the gap after it. `intensity` stays slow — it lights
  /// the picture, and a light that jumped with every syllable would flicker.
  float voice;

  /// Where the rays start, in points from the shell's bottom-left corner.
  /// Placed on the CPU, beside everything else that decides where things are,
  /// so a screenshot and an assertion are looking at the same numbers.
  simd_float2 origin;

  /// sRGB, unpremultiplied; alpha is unused.
  simd_float4 colors[VOICE_GLOW_COLOR_COUNT];
} VoiceGlowUniforms;

#endif /* VoiceGlowUniforms_h */
