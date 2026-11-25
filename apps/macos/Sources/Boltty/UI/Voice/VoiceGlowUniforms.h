#ifndef VoiceGlowUniforms_h
#define VoiceGlowUniforms_h

#include <simd/simd.h>

#define VOICE_GLOW_COLOR_COUNT 6

typedef enum {
  VoiceGlowBufferIndexUniforms = 0
} VoiceGlowBufferIndex;

typedef struct {
  simd_float2 size;
  float pixelSize;

  float cornerRadius;
  float cornerIsContinuous;

  float intensity;
  float beam;
  float opacity;
  float appearance;
  float clock;
  /// Integrated on the CPU: `clock * speed` in the shader would jump whenever the speed changed.
  float flow;

  float reach;

  float orb;
  simd_float2 origin;

  simd_float4 colors[VOICE_GLOW_COLOR_COUNT];
} VoiceGlowUniforms;

#endif /* VoiceGlowUniforms_h */
