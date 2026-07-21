# stress-uv

`stress-uv` is a Linux Bash harness for repeatable CPU and memory stability
screening with [`stress-ng`](https://github.com/ColinIanKing/stress-ng). It runs
focused workloads sequentially, records telemetry and kernel messages, and
produces a conservative `PASS`, `FAIL`, `INCONCLUSIVE`, or `INCOMPLETE` result.
It can also record repeatable local CPU throughput baselines.

It is intended for checking CPU undervolts, CPU overclocks, cache/ring changes,
and memory tuning. It does not modify voltages, clocks, firmware settings, or
power limits.

> [!WARNING]
> Stress testing can crash, reboot, overheat, or corrupt an unstable system.
> Save your work first. Monitor cooling and power delivery. The default 90 °C
> setting is an s-tui warning threshold only; it does **not** stop the workload.
> A successful run reduces uncertainty but cannot prove absolute stability.

## What it does

The harness provides three stability suites, five directly runnable stability
stages, and one independent benchmark mode:

| Mode | Stages, in order |
| --- | --- |
| `cpu` | `cpu-sustained`, `cpu-transition`, `cpu-core-cycle` |
| `memory` | `memory-cache`, `memory-vm` |
| `all` | Every CPU stage, then every memory stage |
| `benchmark` | Single-thread then multi-thread vecfp throughput |

All stages run sequentially. `cpu-core-cycle` also tests the selected logical
CPUs one at a time. This keeps failures attributable to a specific workload or
logical CPU instead of mixing every stressor concurrently.

During a run, `stress-uv`:

1. Prints the exact plan and asks you to type `RUN`, unless `--yes` is used.
2. Authenticates with `sudo` and creates a private timestamped run directory.
3. Records kernel, CPU topology, microcode, tool versions, and initial sensors.
4. Starts optional file telemetry with `turbostat` and `sensors`.
5. Runs each selected `stress-ng` stage and records its exit status and log.
6. Captures kernel messages and checks for MCE, EDAC, lockup, hardware-error,
   verification-error, and out-of-memory evidence.
7. Writes a summary and exits successfully only when the final result is
   `PASS`.

Interactive mode creates a three-pane tmux session with s-tui, the stage
runner, and a live kernel journal. Detach without stopping the run with
`Ctrl-b d`. Use `--no-tui` for unattended or headless execution.

## Workload methodology

Every stability stage adds these common `stress-ng` controls:

```text
--timeout DURATION --abort --verify --metrics-brief --klog-check --log-brief
```

- `--timeout` bounds the stage duration.
- `--abort` stops the other workers when one terminates prematurely.
- `--verify` enables sanity checks for stressors that support verification.
- `--metrics-brief` emits a compact bogo-operation summary.
- `--klog-check` asks stress-ng to report kernel warnings and errors.
- `--log-brief` reduces log prefixes. The harness also supplies `--log-file`.

### `cpu-sustained`

```text
stress-ng --cpu 0 --cpu-method matrixprod
```

`--cpu 0` selects the processor count using stress-ng's zero-worker convention.
`matrixprod` multiplies 128 x 128 double-precision matrices. Upstream describes
it as a strong mix of floating-point, cache, and memory work that is effective
at making a CPU run hot. This stage targets sustained all-CPU load and gross
instability under heat and current draw.

Default duration: `20m`.

### `cpu-transition`

```text
stress-ng --cpu 0 --cpu-method matrixprod --cpu-load 50 --cpu-load-slice 100
```

This uses the same matrix workload at a requested 50% load. A positive
`--cpu-load-slice 100` requests 100 ms busy slices separated by idle periods.
The repeated load changes exercise frequency, voltage, and power-state
transitions. Actual load can differ from the requested percentage because of
scheduling and CPU frequency scaling.

Default duration: `20m`.

### `cpu-core-cycle`

```text
stress-ng --cpu 1 --cpu-method matrixprod --taskset CPU_ID
```

One worker is pinned to one selected logical CPU. The harness repeats the stage
sequentially for every CPU in `--cpu-list`. This can expose a weak core or a
per-core voltage/frequency point that an all-core test masks.

Default duration: `1m` per logical CPU.

### `memory-cache`

```text
stress-ng --cache 0 --cache-level 3
```

This starts cache-thrashing workers using stress-ng's zero-worker convention
and explicitly targets level 3, the last-level cache on typical systems. It is
useful for cache/ring/uncore and memory-path screening. It is not a complete
DRAM test.

Default duration: `20m`.

### `memory-vm`

```text
stress-ng --vm WORKERS --vm-bytes TOTAL_MIB --vm-method all
```

The worker count matches the selected logical CPU count. `--vm-bytes` sets the
total allocation shared across those workers. The allocation is based on the
smaller of Linux `MemAvailable` and the tightest available cgroup v1 or v2
memory headroom. This avoids treating host RAM as available inside a constrained
container or service.

`--vm-method all` requests the available VM methods, which initialize, modify,
and check mapped memory using varied access patterns. The default allocation is
85% of calculated available memory, with at least 16 MiB required per worker.

This is an operating-system-level memory and memory-controller screen. The
upstream stress-ng manual explicitly warns that virtual mappings do not
guarantee any physical address order and should not be used to prove that all
installed memory works. Use a boot-time tool such as Memtest86+ as an additional
test when validating RAM.

Default duration: `3h`.

## Benchmark methodology

`benchmark` is a separate performance mode. It does not run as part of `cpu`,
`memory`, or `all`, and its throughput changes do not alter stability verdicts.
It measures stress-ng's reported vecfp rates:

```text
stress-ng --vecfp 1 --vecfp-method all --taskset FIRST_SELECTED_CPU --metrics
stress-ng --vecfp 0 --vecfp-method all --metrics
```

The first command measures one worker pinned to the first logical CPU selected
by `--cpu-list`. The second uses stress-ng's zero-worker convention to measure
all online CPUs. Each scope gets a warm-up followed by repeated measured runs.
Defaults are a `15s` warm-up and three `60s` measured runs per scope.

The harness extracts only stress-ng's named `Mfp-ops/sec` vecfp metrics. It does
not use stress-ng bogo operations as benchmark scores. For each exact metric it
records the median, minimum, maximum, and population coefficient of variation.
Every metric must appear once in every repetition and in both scopes. Missing,
duplicate, or inconsistent metric sets make the run inconclusive.

These values are for before/after comparisons on the same machine. They depend
on the CPU, stress-ng version and build, compiler, scheduler, thermals, and power
limits. They are not portable public scores and are not comparable to Cinebench.
`compare` rejects runs with different stress-ng versions, CPU selections, online
CPU sets, durations, warm-ups, or repetition counts.

## Prerequisites

Required in all non-dry runs:

- Bash 4 or newer
- Linux
- `stress-ng`
- `sudo`
- `setsid` from util-linux

Required for the default interactive interface:

- `tmux`
- `s-tui`

Optional telemetry:

- `turbostat`, usually provided by your distribution's Linux tools package
- `sensors`, provided by lm-sensors

Install these tools through your distribution's package manager. Tool and
package names vary by distribution. Confirm availability with:

```bash
command -v stress-ng sudo setsid tmux s-tui
command -v turbostat sensors
```

The harness needs sudo access for stress-ng, turbostat when present, and kernel
log collection. It validates sudo before creating a run.

## Installation

```bash
git clone git@github.com:ryodeushii/stress-uv.git
cd stress-uv
./stress-uv --help
```

The tracked `stress-uv` file is executable. No build step or runtime language
package manager is required.

## Usage

Preview the complete plan without sudo or starting a workload:

```bash
./stress-uv all --dry-run
```

Run the CPU suite with the interactive tmux dashboard:

```bash
./stress-uv cpu
```

Run the memory suite headlessly:

```bash
./stress-uv memory --no-tui
```

Run one stage with a shorter duration:

```bash
./stress-uv cpu-sustained --cpu-duration 10m
./stress-uv memory-vm --vm-duration 1h --memory-percent 70
```

Cycle selected logical CPUs:

```bash
./stress-uv cpu-core-cycle --cpu-list 0,2-5,8 --core-duration 2m
```

Run unattended after reviewing the dry-run plan:

```bash
./stress-uv all --no-tui --yes
```

Record a local CPU performance baseline:

```bash
./stress-uv benchmark --no-tui
./stress-uv benchmark --benchmark-warmup 30s --benchmark-duration 2m \
  --benchmark-runs 5
```

Compare two compatible benchmark runs:

```bash
./stress-uv compare runs/20260721-120000-benchmark \
  runs/20260721-130000-benchmark
```

Re-evaluate an existing run directory:

```bash
./stress-uv report runs/20260721-120000-all
```

### Options

| Option | Meaning | Default |
| --- | --- | --- |
| `--cpu-list LIST` | Logical CPUs used by core cycling and VM worker sizing | Online CPUs |
| `--cpu-duration TIME` | Sustained and transition stage duration | `20m` |
| `--core-duration TIME` | Duration for each logical CPU | `1m` |
| `--cache-duration TIME` | Cache stage duration | `20m` |
| `--vm-duration TIME` | VM stage duration | `3h` |
| `--benchmark-duration TIME` | Duration of each measured benchmark run | `60s` |
| `--benchmark-warmup TIME` | Warm-up duration for each benchmark scope | `15s` |
| `--benchmark-runs N` | Measured repetitions per scope (`1`-`20`) | `3` |
| `--memory-percent N` | Calculated available memory used across VM workers (`1`-`90`) | `85` |
| `--output DIR` | Root directory for run artifacts | `./runs` |
| `--refresh-rate SECONDS` | s-tui and turbostat interval | `2` |
| `--temperature-threshold C` | s-tui warning threshold only (`40`-`110`) | `90` |
| `--no-tui` | Disable tmux and s-tui; retain file telemetry | Off |
| `--dry-run` | Print commands without running them | Off |
| `--yes` | Skip the `RUN` confirmation | Off |

Durations accept positive values such as `30s`, `20m`, or `3h`.

## Results and artifacts

Each run creates `RUN_ROOT/TIMESTAMP-MODE/` with private permissions. Important
files include the following. Interrupted runs may not reach the steps that
produce every file.

| Path | Contents |
| --- | --- |
| `summary.txt` | Final result and reasons |
| `state` | Atomic run state and last stage |
| `exit-code` | Harness result for completed or aborted runs |
| `expected-stages` | Exact expected stage manifest |
| `stages.tsv` | Stage label, raw stress-ng exit status, and verdict |
| `STAGE.log` | stress-ng output for a stage or logical CPU |
| `kernel.log` | Kernel messages collected for the run interval |
| `live-kernel.log` | Live journal stream from interactive mode |
| `metadata.txt` | Kernel, CPU topology, microcode, versions, and sensors |
| `telemetry/s-tui.csv` | s-tui samples from interactive mode |
| `telemetry/turbostat.txt` | turbostat samples when available |
| `telemetry/sensors-*.txt` | Before/after lm-sensors snapshots |
| `benchmark.tsv` | Raw vecfp metric values for every measured repetition |
| `benchmark-summary.tsv` | Median, range, and coefficient of variation per metric |
| `benchmark-context.tsv` | CPU selection, stress-ng version, and benchmark protocol |

Verdict rules are deliberately conservative:

- `PASS`: every expected stage completed successfully, no verification or
  hardware error was found, and the kernel log was available.
- `FAIL`: a stressor failure, unexpected stressor signal, verification error,
  or matching kernel hardware error was found.
- `INCONCLUSIVE`: a stage or resource error occurred, a stressor was unsupported,
  the stage manifest was invalid, or the kernel log was unavailable.
- `INCOMPLETE`: the run did not reach its completed state.

The report command returns `0` only for `PASS`; every other result returns `1`.
The compare command returns `0` only when both benchmark contexts and metric
sets are compatible.

## Choosing a stability process

Use this harness as one layer, not the entire validation process:

1. Establish a known-good stock baseline before tuning.
2. Change one voltage, frequency, cache/ring, or memory variable at a time.
3. Use `cpu` for CPU voltage/frequency changes.
4. Use `memory` for DRAM, memory-controller, and cache/ring changes.
5. Use `all` before accepting a configuration for daily use.
6. Add a boot-time Memtest86+ pass for broad physical-memory coverage.
7. Validate real applications and long idle/wake cycles after synthetic tests.
8. Treat any WHEA/MCE/EDAC report, verification mismatch, crash, or unexplained
   process failure as instability until proven otherwise.
9. Use `benchmark` before and after tuning to check local performance, but judge
   stability from the stress suites and real workloads.

Different workloads exercise different instruction mixes and voltage/frequency
points. Passing this suite does not guarantee that Prime95/mprime, y-cruncher,
OCCT, games, compilers, or your normal workload will pass. OCCT is not
integrated because this harness is built around documented, scriptable Linux
interfaces.

## Development

The test suite mocks third-party tools. It does not launch a real stress
workload:

```bash
bash tests/test_stress_uv.sh
```

Tests cover stage ordering, benchmark metric parsing and comparison, cgroup
v1/v2 memory bounds, report integrity, signal cleanup, delayed sudo handoff,
PID reuse, tmux rollback, non-zero tmux base indices, and launcher death. The
optional real sudo boundary check requires cached non-interactive sudo:

```bash
sudo -v
STRESS_UV_TEST_ROOT_CLEANUP=1 bash tests/test_stress_uv.sh
```

## References

- [stress-ng upstream repository](https://github.com/ColinIanKing/stress-ng)
- [stress-ng manual](https://github.com/ColinIanKing/stress-ng/blob/master/stress-ng.1)
- [s-tui upstream repository](https://github.com/amanusk/s-tui)
- [Memtest86+](https://memtest.org/)
