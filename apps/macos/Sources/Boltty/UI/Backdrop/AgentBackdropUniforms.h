//  AgentBackdropUniforms.h
//
//  One definition of the chat backdrop's per-frame state, compiled by Swift
//  through `Boltty-Bridging-Header.h` and by the Metal compiler from
//  `AgentBackdropShaders.metal` — one struct, so a field added on one side
//  cannot silently shift the other.

#ifndef AgentBackdropUniforms_h
#define AgentBackdropUniforms_h

#include <simd/simd.h>

typedef enum {
  AgentBackdropBufferIndexUniforms = 0
} AgentBackdropBufferIndex;

typedef struct {
  /// Shell size in points; the scene is laid out in points so a 1x and a 2x
  /// display draw the same sky.
  simd_float2 size;
  /// Points per pixel: 2 for the sky, ½ on Retina for the stars
  /// (`ChatBackdrop.pixelsPerPoint`).
  float pixelSize;
  /// Which scene, `ChatBackdrop.sceneIndex`: 1 sky, 2 space. The
  /// corner is not the shader's: the view's layer clips to the glass's own
  /// continuous corner, which no formula here matched.
  float scene;
  /// Seconds of drift. Frozen under Reduce Motion.
  float clock;
  /// Overall opacity. The live view fades its layer instead and draws at 1.
  float opacity;
  /// The sky's own ramp for this face (`AgentBackdropSky`): zenith, horizon,
  /// the light on the clouds, their shaded undersides, the sky between
  /// zenith and horizon, the glow where the sun is. sRGB.
  simd_float4 sky[6];
} AgentBackdropUniforms;

#endif /* AgentBackdropUniforms_h */
