//  AgentBackdropUniforms.h
//
//  One definition of the chat backdrop's per-frame state, compiled by Swift
//  through `Boltty-Bridging-Header.h` and by the Metal compiler from
//  `AgentBackdropShaders.metal` — one struct, so a field added on one side
//  cannot silently shift the other.

#ifndef AgentBackdropUniforms_h
#define AgentBackdropUniforms_h

#include <simd/simd.h>

/// The face's six stops, top of its body to the foot.
#define AGENT_BACKDROP_COLOR_COUNT 6

typedef enum {
  AgentBackdropBufferIndexUniforms = 0
} AgentBackdropBufferIndex;

typedef struct {
  /// Shell size in points; the scene is laid out in points so a 1x and a 2x
  /// display draw the same sky.
  simd_float2 size;
  /// Points per pixel: 1 for the soft scenes, ½ on Retina for the sharp
  /// ones (`ChatBackdrop.drawsAtFullScale`).
  float pixelSize;
  /// Which scene, `ChatBackdrop.sceneIndex`: 1 sky, 2 space, 3 matrix. The
  /// corner is not the shader's: the view's layer clips to the glass's own
  /// continuous corner, which no formula here matched.
  float scene;
  /// Seconds of drift. Frozen under Reduce Motion.
  float clock;
  /// Overall opacity, including the fade in and out.
  float opacity;
  /// sRGB, unpremultiplied; alpha is unused.
  simd_float4 colors[AGENT_BACKDROP_COLOR_COUNT];
} AgentBackdropUniforms;

#endif /* AgentBackdropUniforms_h */
