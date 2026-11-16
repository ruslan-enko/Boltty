//  OklabShading.h
//
//  Colour mixing for Boltty's shaders: colours are mixed in Oklab, where a
//  step in lightness looks like one and two far hues do not meet in grey.
//  Metal only; included by the shaders that draw colour.

#ifndef OklabShading_h
#define OklabShading_h

#include <metal_stdlib>

static inline float3 srgbToLinear(float3 c) {
  return metal::select(metal::pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static inline float3 linearToSRGB(float3 c) {
  return metal::select(1.055 * metal::pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static inline float3 srgbToOklab(float3 c) {
  const float3 rgb = srgbToLinear(metal::clamp(c, 0.0, 1.0));
  const float3 lms = metal::pow(float3(
    0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b,
    0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b,
    0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b
  ), 1.0 / 3.0);
  return float3(
    0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
    1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
    0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z
  );
}

static inline float3 oklabToLinearSRGB(float3 c) {
  const float3 lms = float3(
    c.x + 0.3963377774 * c.y + 0.2158037573 * c.z,
    c.x - 0.1055613458 * c.y - 0.0638541728 * c.z,
    c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
  );
  const float3 cube = lms * lms * lms;
  return float3(
    4.0767416621 * cube.x - 3.3077115913 * cube.y + 0.2309699292 * cube.z,
    -1.2684380046 * cube.x + 2.6097574011 * cube.y - 0.3413193965 * cube.z,
    -0.0041960863 * cube.x - 0.7034186147 * cube.y + 1.7076147010 * cube.z
  );
}

static inline bool insideSRGB(float3 c) {
  return metal::all(c >= -0.0005) && metal::all(c <= 1.0005);
}

/// Gamma-encoded sRGB. Out of sRGB, chroma gives way and lightness and hue hold.
static inline float3 oklabToSRGB(float3 c) {
  float3 rgb = oklabToLinearSRGB(c);
  if (!insideSRGB(rgb)) {
    float low = 0.0, high = 1.0;
    for (int step = 0; step < 8; step++) {
      const float mid = (low + high) * 0.5;
      if (insideSRGB(oklabToLinearSRGB(float3(c.x, c.yz * mid)))) { low = mid; } else { high = mid; }
    }
    rgb = oklabToLinearSRGB(float3(c.x, c.yz * low));
  }
  return linearToSRGB(metal::clamp(rgb, 0.0, 1.0));
}

/// Two sRGB colours mixed in Oklab.
static inline float3 srgbMix(float3 a, float3 b, float t) {
  return oklabToSRGB(metal::mix(srgbToOklab(a), srgbToOklab(b), t));
}

/// A brightness ceiling in OKLCH: lightness rolls off past the knee and chroma
/// stays, so a dimmed colour keeps its saturation instead of going grey.
static inline float3 oklabCeiling(float3 c, float knee, float ceiling) {
  if (c.x <= knee) { return c; }
  const float room = ceiling - knee;
  return float3(knee + room * (1.0 - metal::exp(-(c.x - knee) / room)), c.yz);
}

#endif /* OklabShading_h */
