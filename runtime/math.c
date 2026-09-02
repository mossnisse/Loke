/* The elementary functions behind `core:math` (math-plan step 3).
 *
 * One versioned wrapper per public name and width. `core:math` binds these
 * rather than `sqrt` and friends directly, so the Loke package never depends on
 * the host linker's implicit library list, and a width-matched wrapper keeps an
 * `f32` caller from rounding twice through `double`.
 *
 * Every body is one delegation on purpose. The target C library defines the
 * signed zeros, infinities, NaN propagation, and the IEC 60559 `pow` table that
 * `core:math` documents; a wrapper that recomputed any of it would be a second
 * specification to keep in step. A target whose library does not meet that
 * contract is normalized here or is not declared supported — this file is where
 * such a difference belongs, not `core:math` source.
 *
 * The math link input is the target's: the Windows CRT needs no extra flag,
 * Linux adds `-lm`, macOS uses libSystem.
 */
#include "loke_rt.h"

#include <math.h>

double loke_rt_v1_math_floor_f64(double x) { return floor(x); }
float loke_rt_v1_math_floor_f32(float x) { return floorf(x); }

double loke_rt_v1_math_ceil_f64(double x) { return ceil(x); }
float loke_rt_v1_math_ceil_f32(float x) { return ceilf(x); }

double loke_rt_v1_math_round_f64(double x) { return round(x); }
float loke_rt_v1_math_round_f32(float x) { return roundf(x); }

double loke_rt_v1_math_trunc_f64(double x) { return trunc(x); }
float loke_rt_v1_math_trunc_f32(float x) { return truncf(x); }

double loke_rt_v1_math_sqrt_f64(double x) { return sqrt(x); }
float loke_rt_v1_math_sqrt_f32(float x) { return sqrtf(x); }

double loke_rt_v1_math_exp_f64(double x) { return exp(x); }
float loke_rt_v1_math_exp_f32(float x) { return expf(x); }

double loke_rt_v1_math_log_f64(double x) { return log(x); }
float loke_rt_v1_math_log_f32(float x) { return logf(x); }

double loke_rt_v1_math_log2_f64(double x) { return log2(x); }
float loke_rt_v1_math_log2_f32(float x) { return log2f(x); }

double loke_rt_v1_math_log10_f64(double x) { return log10(x); }
float loke_rt_v1_math_log10_f32(float x) { return log10f(x); }

double loke_rt_v1_math_sin_f64(double x) { return sin(x); }
float loke_rt_v1_math_sin_f32(float x) { return sinf(x); }

double loke_rt_v1_math_cos_f64(double x) { return cos(x); }
float loke_rt_v1_math_cos_f32(float x) { return cosf(x); }

double loke_rt_v1_math_tan_f64(double x) { return tan(x); }
float loke_rt_v1_math_tan_f32(float x) { return tanf(x); }

double loke_rt_v1_math_asin_f64(double x) { return asin(x); }
float loke_rt_v1_math_asin_f32(float x) { return asinf(x); }

double loke_rt_v1_math_acos_f64(double x) { return acos(x); }
float loke_rt_v1_math_acos_f32(float x) { return acosf(x); }

double loke_rt_v1_math_atan_f64(double x) { return atan(x); }
float loke_rt_v1_math_atan_f32(float x) { return atanf(x); }

double loke_rt_v1_math_mod_f64(double a, double b) { return fmod(a, b); }
float loke_rt_v1_math_mod_f32(float a, float b) { return fmodf(a, b); }

double loke_rt_v1_math_hypot_f64(double a, double b) { return hypot(a, b); }
float loke_rt_v1_math_hypot_f32(float a, float b) { return hypotf(a, b); }

double loke_rt_v1_math_pow_f64(double a, double b) { return pow(a, b); }
float loke_rt_v1_math_pow_f32(float a, float b) { return powf(a, b); }

double loke_rt_v1_math_atan2_f64(double a, double b) { return atan2(a, b); }
float loke_rt_v1_math_atan2_f32(float a, float b) { return atan2f(a, b); }
