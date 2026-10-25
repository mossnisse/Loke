# Performance baselines

These records are comparison inputs for [perf.ps1](../../perf.ps1). Source
hashes in each record prevent comparisons across changed workload inputs. Use
the same machine, tools, and measurement settings for later comparisons; the
figures are observations, not performance thresholds.

## Provenance normalization

[provenance-normalization-before.json](provenance-normalization-before.json)
was captured on 2026-10-25 for
[stage 1](../../provenance-normalization-contract.md#behavioral-and-summary-baseline).
The compiler and LSP were built from commit
`81d478b0823daf46499e597fdac8a018c0c3ca3c`; the additional
[provenance workload](../provenance.loke) is part of stage 1 and its source hash
is included in the record. No compiler implementation changes preceded capture.

Measurement conditions:

- Windows 10, build 19045, x64; 6 logical processors.
- Processor identifier: `Intel64 Family 6 Model 158 Stepping 12, GenuineIntel`.
- Odin `dev-2026-10-nightly:84bc3fc`.
- Default `perf.ps1` settings: three runs, fastest successful compiler/runtime
  run; LSP timings use the script's existing aggregation. No test suite or other
  compiler workload ran concurrently with capture.
- `lokec.exe` SHA-256:
  `a225183a1fb19f59a45dae070a73c81d3e601f5ee817fb9f69b48dd7ee0b8432`.
- `loke-lsp.exe` SHA-256:
  `761dac439aa0855b82a6d7c0d1702578d7a02c5ad7d82996a67f3f2a31eaeeae`.

Capture command, from the repository root:

```powershell
.\perf.ps1 -Out bench/baselines/provenance-normalization-before.json
```

Selected results from all 24 records:

| Workload | Front end (ms) | Full build (ms) | Compiler peak (MB) |
| --- | ---: | ---: | ---: |
| `bench/provenance.loke` | 36 | 296 | 12.3 |
| `bench/workspace` | 404 | 1131 | 63.5 |
| `examples/corpus_runner.loke` | 648 | 4844 | 98.4 |

The workspace LSP measured 577 ms to open, 388 ms for a root edit, 487 ms for a
library edit, 384 ms for completion, and 107.2 MB peak working set. Front-end
figures include LLVM text emission (`-emit-ll`); full builds use `-opt=speed`.
Compiler peak is the larger process peak from those two selected runs.

After rebuilding a later compiler and LSP, compare without overwriting the
baseline:

```powershell
.\perf.ps1 -Baseline bench/baselines/provenance-normalization-before.json -Out tests/tmp/provenance-normalization-after.json
```

These records do not isolate provenance analysis time, normalization time,
graph replay counts, or analysis arena peak memory. Add those measurements when
the normalized replay boundary is introduced; retain the process-level record
for total cost comparisons.
