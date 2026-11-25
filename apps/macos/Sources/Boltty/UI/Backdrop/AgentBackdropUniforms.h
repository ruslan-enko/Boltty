#ifndef AgentBackdropUniforms_h
#define AgentBackdropUniforms_h

#include <simd/simd.h>

typedef enum {
  AgentBackdropBufferIndexUniforms = 0
} AgentBackdropBufferIndex;

typedef struct {
  simd_float2 size;
  float pixelSize;
  float scene;
  float clock;
  float opacity;
  simd_float4 sky[6];
} AgentBackdropUniforms;

#endif /* AgentBackdropUniforms_h */
