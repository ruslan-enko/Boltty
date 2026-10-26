#ifndef MascotUniforms_h
#define MascotUniforms_h

#include <simd/simd.h>

#define MASCOT_STOP_COUNT 6

typedef enum {
  MascotBufferIndexUniforms = 0,
  MascotBufferIndexField = 1
} MascotBufferIndex;

#define MASCOT_FIELD_SIZE 512
#define MASCOT_FIELD_EXTENT 20.0

/// Order is the shader's switch; Swift names these, never numbers them.
typedef enum {
  MascotShapeBloom = 0,
  MascotShapeCapsule,
  MascotShapeDaisy,
  MascotShapeHex,
  MascotShapeOrb,
  MascotShapeTriangle
} MascotShapeID;

typedef enum {
  MascotGradientSunrise = 0,
  MascotGradientSweep,
  MascotGradientGlow
} MascotGradientID;

typedef struct {
  simd_float4 frame;
  simd_float4 axisX;
  simd_float4 axisY;
  simd_float4 axisZ;
  simd_float4 body;
  simd_float4 stops[MASCOT_STOP_COUNT];
  simd_float4 eyes[2];
  simd_float4 looks[2];
  simd_float4 shape;
  simd_float4 build;
  simd_float4 face;
  simd_float4 extent;
  simd_float4 finish;
  simd_float4 ink;
} MascotUniforms;

#endif /* MascotUniforms_h */
