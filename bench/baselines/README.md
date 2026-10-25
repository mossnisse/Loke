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

### Storage and place normalization (stage 2)

[provenance-normalization-stage2.json](provenance-normalization-stage2.json)
records the stage 2 working tree following `ba8443f`, measured on 2026-10-25
with the same machine, tools, repeat count, and unchanged workload source hashes
as the initial baseline. No test suite or other compiler workload ran during
capture. Compiler and LSP SHA-256 values were:

- `lokec.exe`:
  `12dfe0741ea01e3dcac2acbb4ce256f1f201a898d38de5250be69eac06e1c285`.
- `loke-lsp.exe`:
  `bef30fa2265c9c845a02c0a7ec0b11d8f7b46591d07ccd18f4c708a3a7e4da7e`.

Capture command:

```powershell
.\perf.ps1 -Baseline bench/baselines/provenance-normalization-before.json -Out bench/baselines/provenance-normalization-stage2.json
```

| Workload | Initial front end (ms) | Stage 2 front end (ms) | Initial / stage 2 compiler peak (MB) |
| --- | ---: | ---: | ---: |
| `bench/provenance.loke` | 36 | 38 | 12.3 / 12.3 |
| `bench/workspace` | 404 | 453 | 63.5 / 63.6 |
| `examples/corpus_runner.loke` | 648 | 728 | 98.4 / 98.2 |

The measured front-end increases are about 6%, 12%, and 12%, respectively.
Workspace LSP timings increased by 3–5%, with peak working set changing from
107.2 to 106.6 MB. Executable sizes and checked benchmark outputs were unchanged.
These observations include ordinary timing noise and do not isolate the cost
of provenance analysis. Stage 2 still reconstructs graphs and copies normalized
descriptions between region passes; stage 4's replay boundary should be measured
against both records. The initial representation trades some measured time for
shared storage semantics without increasing retained whole-program body state.

### Transfer normalization (stage 3)

[provenance-normalization-stage3.json](provenance-normalization-stage3.json)
records the stage 3 working tree following `fcac12d`, measured on 2026-10-25
with the same machine, tools, repeat count, and unchanged workload source hashes
as the previous records. No test suite or other compiler workload ran during
capture. Compiler and LSP SHA-256 values were:

- `lokec.exe`:
  `6f503fefc992f598410361f195cd23071fdcb6fc10f1f6071072cdc53f4333d3`.
- `loke-lsp.exe`:
  `294c0226fd56371a3449dc32ab5df018bd8f08889c22fb971d6044bc37f2c971`.

Capture command:

```powershell
.\perf.ps1 -Baseline bench/baselines/provenance-normalization-stage2.json -Out bench/baselines/provenance-normalization-stage3.json
```

| Workload | Initial / stage 2 / stage 3 front end (ms) | Stage 2 / stage 3 compiler peak (MB) |
| --- | ---: | ---: |
| `bench/provenance.loke` | 36 / 38 / 41 | 12.3 / 12.3 |
| `bench/workspace` | 404 / 453 / 439 | 63.6 / 63.6 |
| `examples/corpus_runner.loke` | 648 / 728 / 760 | 98.2 / 98.3 |

Relative to stage 2, the selected front-end changes are +8%, −3%, and +4%.
Relative to the initial compiler, they are +14%, +9%, and +17%. Workspace LSP
timings increased by 3–5%: open 620 ms, root edit 419 ms, library edit 520 ms,
and completion 424 ms. Its peak working set changed from 106.6 to 106.4 MB.
All 24 records completed, executable sizes stayed unchanged, and benchmark
outputs matched. These measurements include timing noise and cover the complete
front end rather than provenance alone. Stage 3 still copies normalized input
between graph passes; stage 4 must measure the complete replay boundary against
all three records before making performance claims.

### Fact replay (stage 4)

[provenance-normalization-stage4.json](provenance-normalization-stage4.json)
records the stage 4 working tree following `d957b5c`, measured on 2026-10-25
with the same machine, tools, repeat count, and unchanged workload source hashes
as the preceding records. No test suite or other compiler workload ran during
capture. Compiler and LSP SHA-256 values were:

- `lokec.exe`:
  `c147692ef85191c7fa692f6fa7e532c799b32b6df7cf48a317d848b22ea0f563`.
- `loke-lsp.exe`:
  `1b04c7a3429d2b461f9b6b6b8f7fa49e5424ef8681ae2c5e85f08a59dd63df33`.

```powershell
.\perf.ps1 -Baseline bench/baselines/provenance-normalization-stage3.json -Out bench/baselines/provenance-normalization-stage4.json
```

| Workload | Initial / stage 3 / stage 4 front end (ms) | Stage 3 / stage 4 compiler peak (MB) |
| --- | ---: | ---: |
| `bench/provenance.loke` | 36 / 41 / 41 | 12.3 / 12.6 |
| `bench/workspace` | 404 / 439 / 461 | 63.6 / 65.4 |
| `examples/corpus_runner.loke` | 648 / 760 / 813 | 98.3 / 101.5 |

The selected front-end changes versus stage 3 are 0%, +5%, and +7%; compiler
peak working set increases by 2–3%. Workspace LSP measurements were open 620 ms,
root edit 463 ms, library edit 550 ms, completion 449 ms, and peak working set
108.5 MB. Open time was unchanged; the other operations increased by 6–11%.
All 24 records completed, executable sizes stayed unchanged, and benchmark
outputs matched. These observations include timing noise. The remaining final
event bridge is still included in the cost; this record establishes the next
migration stage's comparison point, rather than demonstrating a general speedup.

The [first stage 4 capture](provenance-normalization-stage4-initial.json) is kept
as evidence of a performance problem found during this work. It recorded selected
front-end times of 50, 667, and 1048 ms, respectively, and workspace LSP root-edit
time of 642 ms. That build used compiler SHA-256
`e5d561194d101879a481ff5711c59d3f4067b8e1370f7effecf693a451d880bd`
and LSP SHA-256
`667cab4e4e4f333d668488773be3344eb7bd9db3ec180d575812fede91e8c55d`.
Recording was trimmed to provenance-relevant values and writes. Replay now starts
from construction facts, zero-weight graphs reuse their initial events, and
the event bridge shares normalized metadata until it needs a private extension.
Those changes remove a redundant fact round per body and most of the initial
overhead without changing the regression corpus.

The [profiling probe](../provenance_profile/main.odin) records whole-check costs
across all summary visits, using fresh sessions and keeping all phase figures
from the fastest of three complete checks. Capture command:

```powershell
odin run bench/provenance_profile -- bench/provenance.loke bench/workspace examples/corpus_runner.loke > bench/baselines/provenance-normalization-stage4-profile.json
```

| Workload | Body builds | Fact replays | Normalize / replay / materialize (ms) | Peak sampled build arena bytes |
| --- | ---: | ---: | ---: | ---: |
| `bench/provenance.loke` | 109 | 97 | 6.1 / 3.2 / 4.1 | 263593 |
| `bench/workspace` | 1554 | 726 | 122.8 / 26.9 / 59.6 | 421614 |
| `examples/corpus_runner.loke` | 1965 | 1111 | 196.8 / 44.5 / 110.3 | 1450578 |

The [final probe record](provenance-normalization-stage4-profile.json) also keeps
total checking time, excluding LLVM emission. It is therefore a different
measurement from `perf.ps1`'s front-end column. Arena figures include construction,
carry, replay, and final graph storage sampled at phase boundaries; they exclude
the subsequent borrow solver and are neither committed virtual memory nor process
working set. The construction graph remains allocated for the body's build to
share its metadata. The
[initial probe](provenance-normalization-stage4-initial-profile.json) recorded
206 / 2280 / 3076 fact replays and checking times of 36.5 / 560.0 / 901.2 ms for
the same workloads; the final probe records 27.9 / 364.2 / 647.8 ms. These counters
locate the costs still paid by normalization and final event materialization.
