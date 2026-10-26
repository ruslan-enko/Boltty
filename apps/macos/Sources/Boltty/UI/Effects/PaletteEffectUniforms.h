#ifndef PaletteEffectUniforms_h
#define PaletteEffectUniforms_h

#include <simd/simd.h>

typedef enum {
  PaletteEffectBufferIndexUniforms = 0
} PaletteEffectBufferIndex;

typedef enum {
  PaletteEffectTextureIndexImage = 0
} PaletteEffectTextureIndex;

typedef struct {
  simd_float2 size;
  float imageAspect;
  float pixelSize;
  float cornerRadius;
  float cornerIsContinuous;
  float progress;
  float blur;
  float aberration;
  float zoom;
  float opacity;
} PaletteRevealUniforms;

typedef struct {
  simd_float2 size;
  simd_float4 frame;
  simd_float2 velocity;
  float lag;
  float pixelSize;
  float cornerRadius;
  float opacity;
} PaletteWhipUniforms;

#define PaletteSelectionGlowStops 16

typedef struct {
  simd_float2 size;
  simd_float4 region;
  float pixelSize;
  float cornerRadius;
  float lineWidth;
  float glowDepth;
  float glowStrength;
  float haloReach;
  float haloStrength;
  float clock;
  float waveAmplitude;
  float driftAmplitude;
  simd_float4 colors[PaletteSelectionGlowStops];
} PaletteSelectionGlowUniforms;

#endif /* PaletteEffectUniforms_h */
