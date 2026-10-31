# UCRT and reproducible math comparison

The slowdown is real on the measured machine. It remains with runtime inputs,
observable results, optimized builds, and the UCRT's FMA path disabled. It is
mostly the cost of the current reproducible kernels, not a benchmark that
accidentally removes the UCRT calls. This does not establish a minimum cost
for deterministic math: the reproducible package promises correct rounding
as well as reproducibility, and its algorithms have room to improve. The
first [measurements](#measurements-on-2026-10-29) found two improvements;
[after them](#measurements), the functions but sqrt take 1.9 to 4.7 times
the UCRT's time, where they took 2.1 to 9.4.

## Reproduce

From the repository root:

```powershell
New-Item -ItemType Directory -Force tests/tmp | Out-Null
.\lokec.exe bench/math_compare -opt=speed -o tests/tmp/math_compare.exe
.\tests\tmp\math_compare.exe
.\tests\tmp\math_compare.exe legacy
.\tests\tmp\math_compare.exe grid
.\tests\tmp\math_compare.exe dependent
$env:LOKE_DISPATCH_CPU = "x86-64"; .\tests\tmp\math_compare.exe; Remove-Item Env:LOKE_DISPATCH_CPU
.\lokec.exe bench/math_compare -opt=speed -cpu=x86-64-v3 -o tests/tmp/math_compare_v3.exe
.\tests\tmp\math_compare_v3.exe
```

The program's output depends on timing, so it lives in a folder of its own,
outside the `bench/*.loke` programs that [perf.ps1](../../perf.ps1) runs
against an `.expected` file.

The [benchmark](main.loke) compares the public APIs with the same
runtime function-pointer loop. It prepares 4,096 seeded inputs outside the
timer, warms each implementation, then takes five samples of 1,048,576 calls
each, reversing implementation order each sample. Four independent sums
consume independent-call results. The sums are printed after timing. A
`dependent` run instead feeds the previous result, multiplied by 1e-12, into
the next input; its timings include that multiply and addition. It is a
dependency-chain workload, not isolated instruction latency, and the two
implementations can then receive slightly different inputs.

`grid` replaces the first argument with ordered, evenly spaced values; the
second argument remains seeded. `legacy` calls `_set_FMA3_enable(0)` before
measurement. Other runs leave the UCRT's default selection in place. Neither
option changes the reproducible algorithms. `LOKE_DISPATCH_CPU=x86-64`
makes a baseline build run its plain copies of
[dispatched procedures](../../compiler-guide.md#cpu-levels) on a processor that has
`x86-64-v3`.

Input ranges are [-10, 10) for exp; [0.5, 2) for logarithms; [-700, 700) for
trigonometric functions; [-0.999, 0.999) for asin/acos; [-20, 20) for atan;
[-10, 10) for atan2's first argument; [0.25, 4) for pow's base; and
[0.125, 1000) for hypot's first argument and sqrt. All second arguments
are in [-10, 10). Float inputs are narrowed from the same generated doubles.

These are scalar, warm-cache microbenchmarks. Inputs repeat every 4,096 calls;
this is neither a full-domain sample nor a simulation workload. CPU affinity
and background activity are not controlled. Compare medians and ranges, not
individual nanoseconds. Do not run the variants concurrently. Checksums keep
the work observable; equal aggregate sums do not prove bitwise equality of
every result or correct rounding.

## Measurements

Measured on 2026-10-30 at source revision
`aa114f6cec97e756cea5a3242c831a5227e0d292`, with the same machine,
toolchain, and options as [on 2026-10-29](#measurements-on-2026-10-29). The
`lokec.exe` used has SHA-256
`4384270A491A4F1D3B703079961FC960E0A30D4611C9E45AAC8D71D80B78E4FE`. The
[CSV](../baselines/math-compare-2026-10-30.csv) records each set of five
samples as before; its `plain` mode caps dispatch at baseline. A first run
of every mode was disturbed, its dependent UCRT times nearly doubling, and
was discarded; one later random-mode run was noisy too, and its rows were
replaced by a rerun. Times are nanoseconds per call.

Default UCRT selection, seeded independent inputs. The repro column is a
baseline build, whose `f64` functions dispatch to their FMA copies on this
processor; the next two columns are its plain copies and a `x86-64-v3`
build. The last is the repro column of 2026-10-29.

| Function | UCRT | repro | Ratio | plain | v3 | 10-29 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| exp | 4.42 | 19.46 | 4.41 | 20.20 | 17.92 | 19.97 |
| log | 5.76 | 19.98 | 3.47 | 28.25 | 17.53 | 28.30 |
| log2 | 8.83 | 24.06 | 2.73 | 39.43 | 23.56 | 38.69 |
| log10 | 6.58 | 25.95 | 3.94 | 41.03 | 26.99 | 43.51 |
| sin | 9.67 | 38.12 | 3.94 | 44.58 | 36.27 | 47.92 |
| cos | 9.41 | 36.90 | 3.92 | 42.94 | 35.65 | 45.44 |
| tan | 11.99 | 51.50 | 4.30 | 63.53 | 48.71 | 64.60 |
| asin | 10.10 | 42.71 | 4.23 | 54.86 | 41.04 | 74.14 |
| acos | 9.54 | 44.07 | 4.62 | 57.14 | 42.37 | 75.22 |
| atan | 7.50 | 35.16 | 4.69 | 42.35 | 34.35 | 46.14 |
| atan2 | 19.54 | 37.19 | 1.90 | 40.97 | 33.45 | 40.55 |
| pow | 14.22 | 62.05 | 4.36 | 74.98 | 60.55 | 73.25 |
| hypot | 3.93 | 17.41 | 4.43 | 21.02 | 13.57 | 32.21 |
| sqrt | 1.41 | 1.68 | 1.20 | 1.65 | 1.75 | 1.63 |
| exp_f32 | 3.71 | 13.42 | 3.61 | 12.48 | 11.34 | 19.63 |
| sin_f32 | 10.71 | 27.87 | 2.60 | 24.54 | 23.71 | 59.78 |
| asin_f32 | 11.65 | 27.19 | 2.33 | 22.40 | 21.44 | 41.37 |
| pow_f32 | 10.25 | 37.99 | 3.71 | 34.30 | 31.74 | 87.56 |
| sqrt_f32 | 1.17 | 1.42 | 1.21 | 1.43 | 1.80 | 1.65 |

The `_f32` functions are not dispatched, so their repro and plain columns
measure the same code in two processes; their difference, up to 3 ns, is
this run's noise. Every repro checksum, in every mode, equals 2026-10-29's,
which is consistent with the changes leaving each result's bits alone, as
`tests/repro_test.odin` checked each of them to.

The dependency model still matters. With dependent inputs, exp is 15.86
versus 36.70 ns (2.31 times), sin 19.23 versus 51.14 (2.66), asin 21.98
versus 59.13 (2.69), and pow 27.87 versus 77.24 (2.77). On the ordered grid,
asin remains the outlier at 5.73 versus 40.49 ns (7.06 times). With the
UCRT's legacy path, exp is 5.74 versus 18.63 ns, sin 13.69 versus 39.10, and
pow 21.20 versus 60.33.

What remains of the `f64` gap is in the double-`f64` kernels' arithmetic;
the [experiments of 2026-10-30](../../comments.md#standard-library-api-choices)
found that neither branch removal in the trigonometric kernels nor folding
the logarithm constants' splits recovers much of it.

## Measurements on 2026-10-29

The rest of this report is the first measurement and the analysis that led
to the kernel changes since, in `6792eae0`, `cfae8399`, `e4a76fa7`,
`b81d6f01`, and `ddd0dcf7`. Its descriptions of the implementation are of
that revision.

Measured with Clang 22.1.8, MSVC 14.44.35207, Windows SDK
10.0.26100.0, and processor identifier
`Intel64 Family 6 Model 158 Stepping 12, GenuineIntel`. All builds use
`-opt=speed` and contraction off. Unless marked `v3` or `fma`, they target
baseline x86-64. The [CSV](../baselines/math-compare-2026-10-29.csv) records
the median, minimum, maximum, and checksums for each set of five samples.
Times are nanoseconds per call and include loop, argument-load, indirect-call,
and result-consumption costs.

Compiler/library source revision: `0e7e97f5e67e842914c635ec1dad2de9daecb975`.
The `lokec.exe` used has SHA-256
`006EEF24F7B6E99E5D603C461B1BD7AEC4F9D90163C9AB889121DEC0C4B4E2E5`.

Default UCRT selection, seeded independent inputs:

| Function | UCRT | repro | Ratio |
| --- | ---: | ---: | ---: |
| exp | 4.44 | 19.97 | 4.50 |
| log | 5.59 | 28.30 | 5.06 |
| sin | 9.94 | 47.92 | 4.82 |
| cos | 10.68 | 45.44 | 4.25 |
| tan | 11.95 | 64.60 | 5.41 |
| asin | 10.57 | 74.14 | 7.02 |
| acos | 9.50 | 75.22 | 7.92 |
| atan | 8.20 | 46.14 | 5.63 |
| atan2 | 19.28 | 40.55 | 2.10 |
| pow | 13.39 | 73.25 | 5.47 |
| hypot | 3.70 | 32.21 | 8.72 |
| sqrt | 1.43 | 1.63 | 1.14 |
| exp_f32 | 3.37 | 19.63 | 5.83 |
| sin_f32 | 9.01 | 59.78 | 6.63 |
| pow_f32 | 9.28 | 87.56 | 9.44 |

Forcing the legacy UCRT path still leaves exp at 5.57 versus 19.17 ns,
sin at 12.08 versus 42.40 ns, and pow at 21.23 versus 74.58 ns. FMA selection
therefore explains part of the advantage, not the whole gap. Choosing v3
alone also leaves a substantial gap; it does not rewrite repro's explicit
software exact-product algorithm into an explicit fused operation.

The distribution and dependency model matter. On the ordered grid, asin is
5.54 versus 64.23 ns (11.59 times), compared with 7.02 times on seeded inputs.
With dependent inputs, exp is 15.67 versus 35.32 ns (2.25 times), compared
with 4.50 times for independent calls. The earlier measurements in
[open questions](../../open-questions.md#deterministic-math-functions) are broadly
consistent with these results, but their original timing programs were not
found among the tracked files, so their exact loops cannot be audited here.

### Where the work goes

The [platform bindings](../../core/math/math.loke) forward transcendental calls
to the CRT. The optimized benchmark's `crt_exp` adapter is a tail jump to
`exp`. The emitted assembly of `sample.f64` and `sample.f32` retains the
indirect calls inside both nested loops, between the clock reads. It neither
folds them to constants nor hoists their results out of the repetition loop.
The common timing loops have no per-call frame-pop or index-check call.

The [repro arithmetic](../../core/math/repro/arith.loke) computes high/low pairs,
including Dekker's software exact product, then checks whether both ends of
an error interval round to the same float. [Exp](../../core/math/repro/exp.loke)
does extended-precision range reduction and polynomial/table reconstruction;
[pow](../../core/math/repro/pow.loke) combines a more accurate logarithm with
that exponential. The assembly retains long chains of dependent floating
operations. The claim is about this implementation, not a profiled percentage
for each operation.

[Asin/acos](../../core/math/repro/arc.loke) and
[hypot](../../core/math/repro/hypot.loke) also used a software reciprocal-square-root
estimate and four Newton steps in `pair_root`, followed by residual correction.
In contrast, both public sqrt implementations use `sqrtsd`/`sqrtss`;
repro adds special-case/NaN normalization. Their small measured difference
is a control against a general compiler or package-overhead explanation.

Float versions need not be cheaper: `trig_f32` used the same double-pair
`trig_kernel` as the double version, and `pow_f32_of` still called `pow_log`
and `exp_kernel`. They additionally decide rounding to float.
`f32_decided` performs exponent extraction, masks, variable shifts, and
midpoint comparisons; the generated assembly includes these operations.
This explains why narrowing the API does not imply less kernel work, without
attributing the entire float/double timing difference to one helper.

Slow fallbacks are not the main explanation for this input set. In a separate,
untimed copy of the package, counters at the entry of each public operation's
fixed-point fallback counted the following calls out of 4,096 seeded inputs:

| Fallback count | Functions |
| ---: | --- |
| 0 | exp, cos, asin, atan2, pow, hypot, sqrt, all five measured float variants |
| 1 | log, sin, tan, atan |
| 2 | log2, acos |
| 3 | log10 |

The counter copy was not used for the timing results. Other inputs, notably
subnormal results, huge trig arguments, and hard rounding cases, can have
very different costs. The benchmark does not measure their worst case.

### Optimization experiments

Two separate temporary package copies tested whether implementation choices
account for part of the cost. Neither change was applied to the library
then; both were adopted afterwards, with revised bounds and validation, in
`two_product` ([arith.loke](../../core/math/repro/arith.loke)) and
`pair_root` ([arc.loke](../../core/math/repro/arc.loke)):

- `fma`: on v3, replace only `two_product` with `p := a*b` and
  `return {p, math.fma(a, b, 0.0 - p)}`. Against the unchanged v3 build,
  repro pow fell from 70.32 to 54.83 ns, asin from 66.72 to 51.27 ns,
  and hypot from 25.83 to 20.72 ns.
- `root`: at baseline x86-64, replace only `pair_root`'s estimate/Newton
  sequence through `wh := rh*y` with `wh := math.sqrt(rh)`, keeping its
  high/low residual correction. Against the unchanged baseline, repro hypot
  fell from 32.21 to 20.18 ns and asin from 74.14 to 59.43 ns.

The CSV labels these experimental results separately. They are directional
measurements from separate process runs, subject to the same timing noise.
All five repeated checksums were stable in each mode, and the two experiments
and unchanged v3 build retained the baseline's reproducible checksums.
That is not numerical validation of these substitutions: a production change
needs updated error bounds, special-case review, and the independent oracle
suite, including hard cases. The experiments show that the full observed
slowdown is not an unavoidable price of determinism.
