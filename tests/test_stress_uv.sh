#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HARNESS="$ROOT_DIR/stress-uv"
TEST_TMP=""
TESTS_RUN=0
TESTS_FAILED=0

setup() {
    TEST_TMP=$(mktemp -d)
}

teardown() {
    rm -rf -- "$TEST_TMP"
}

fail() {
    printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
}

assert_contains() {
    local haystack=$1
    local needle=$2

    [[ $haystack == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
    local haystack=$1
    local needle=$2

    [[ $haystack != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

assert_file_contains() {
    local file=$1
    local needle=$2

    [[ -f $file ]] || {
        fail "expected file to exist: $file"
        return
    }
    assert_contains "$(< "$file")" "$needle"
}

assert_equals() {
    local actual=$1
    local expected=$2

    [[ $actual == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

assert_order() {
    local haystack=$1
    shift
    local previous=-1
    local needle
    local prefix
    local position

    for needle in "$@"; do
        prefix=${haystack%%"$needle"*}
        if [[ $prefix == "$haystack" ]]; then
            fail "missing ordered item: $needle"
            return
        fi
        position=${#prefix}
        if (( position <= previous )); then
            fail "item is out of order: $needle"
            return
        fi
        previous=$position
    done
}

wait_for_file() {
    local file=$1
    local attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s $file ]] && return 0
        sleep 0.02
    done
    return 1
}

wait_for_exit() {
    local pid=$1
    local attempt

    for ((attempt = 0; attempt < 300; attempt++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.02
    done
    return 1
}

wait_for_tmux_exit() {
    local session=$1
    local attempt

    for ((attempt = 0; attempt < 400; attempt++)); do
        tmux has-session -t "$session" 2>/dev/null || return 0
        sleep 0.02
    done
    return 1
}

wait_for_state() {
    local file=$1
    local expected=$2
    local attempt

    for ((attempt = 0; attempt < 400; attempt++)); do
        [[ -r $file ]] && [[ $(< "$file") == *"status=$expected"* ]] && return 0
        sleep 0.02
    done
    return 1
}

run_test() {
    local name=$1
    shift
    local failures_before

    TESTS_RUN=$((TESTS_RUN + 1))
    failures_before=$TESTS_FAILED
    setup
    "$@"
    if (( TESTS_FAILED == failures_before )); then
        printf 'ok %d - %s\n' "$TESTS_RUN" "$name"
    fi
    teardown
}

test_help_lists_suites_and_stages() {
    local output

    output=$("$HARNESS" --help)
    assert_contains "$output" 'cpu-sustained'
    assert_contains "$output" 'cpu-transition'
    assert_contains "$output" 'cpu-core-cycle'
    assert_contains "$output" 'memory-cache'
    assert_contains "$output" 'memory-vm'
    assert_contains "$output" 'benchmark'
    assert_contains "$output" '--benchmark-duration'
    assert_contains "$output" '--benchmark-warmup'
    assert_contains "$output" '--benchmark-runs'
    assert_contains "$output" 'compare BASELINE_RUN CANDIDATE_RUN'
    assert_contains "$output" 'report RUN_DIR'
}

test_benchmark_dry_run_uses_vecfp_repetitions() {
    local output

    output=$("$HARNESS" benchmark --dry-run --cpu-list 2 \
        --benchmark-duration 30s --benchmark-warmup 5s --benchmark-runs 2)

    assert_order "$output" \
        'STAGE benchmark-single-warmup cpu=2' \
        'STAGE benchmark-single-run-1 cpu=2' \
        'STAGE benchmark-single-run-2 cpu=2' \
        'STAGE benchmark-multi-warmup' \
        'STAGE benchmark-multi-run-1' \
        'STAGE benchmark-multi-run-2'
    assert_contains "$output" '--vecfp 1 --vecfp-method all --taskset 2 --timeout 5s'
    assert_contains "$output" '--vecfp 0 --vecfp-method all --timeout 30s'
    assert_contains "$output" '--metrics'
    assert_not_contains "$output" '--metrics-brief'
}

test_cpu_dry_run_is_sequential_and_cycles_each_cpu() {
    local output

    output=$("$HARNESS" cpu --dry-run --cpu-list 0,2-3 \
        --cpu-duration 20s --core-duration 1s)

    assert_order "$output" \
        'STAGE cpu-sustained' \
        'STAGE cpu-transition' \
        'STAGE cpu-core-cycle cpu=0' \
        'STAGE cpu-core-cycle cpu=2' \
        'STAGE cpu-core-cycle cpu=3'
    assert_contains "$output" '--cpu-load 50 --cpu-load-slice 100'
    assert_contains "$output" '--taskset 2 --timeout 1s'
}

test_all_dry_run_orders_cpu_before_memory() {
    local output

    output=$("$HARNESS" all --dry-run --cpu-list 0 \
        --cpu-duration 1s --core-duration 1s \
        --cache-duration 1s --vm-duration 1s)

    assert_order "$output" \
        'STAGE cpu-sustained' \
        'STAGE cpu-transition' \
        'STAGE cpu-core-cycle cpu=0' \
        'STAGE memory-cache' \
        'STAGE memory-vm'
    assert_contains "$output" 'MEMORY target=85%'
    assert_contains "$output" '--vm-bytes '
    assert_not_contains "$output" '--vm-bytes 85%'
}

test_vm_allocation_respects_cgroup_v2_headroom() {
    local output

    mkdir -p "$TEST_TMP/proc/self" "$TEST_TMP/cgroup/test"
    printf 'MemAvailable:    8388608 kB\n' > "$TEST_TMP/proc/meminfo"
    printf '0::/test\n' > "$TEST_TMP/proc/self/cgroup"
    printf '1073741824\n' > "$TEST_TMP/cgroup/test/memory.max"
    printf '268435456\n' > "$TEST_TMP/cgroup/test/memory.current"

    output=$(STRESS_UV_PROC_ROOT="$TEST_TMP/proc" \
        STRESS_UV_CGROUP_ROOT="$TEST_TMP/cgroup" \
        "$HARNESS" memory-vm --dry-run --cpu-list 0-1 --memory-percent 50)

    assert_contains "$output" '--vm-bytes 384M'
}

test_vm_allocation_respects_cgroup_v1_headroom() {
    local output

    mkdir -p "$TEST_TMP/proc/self" "$TEST_TMP/cgroup/memory/test"
    printf 'MemAvailable:    8388608 kB\n' > "$TEST_TMP/proc/meminfo"
    printf '5:memory:/test\n' > "$TEST_TMP/proc/self/cgroup"
    printf '1073741824\n' > "$TEST_TMP/cgroup/memory/test/memory.limit_in_bytes"
    printf '268435456\n' > "$TEST_TMP/cgroup/memory/test/memory.usage_in_bytes"

    output=$(STRESS_UV_PROC_ROOT="$TEST_TMP/proc" \
        STRESS_UV_CGROUP_ROOT="$TEST_TMP/cgroup" \
        "$HARNESS" memory-vm --dry-run --cpu-list 0-1 --memory-percent 50)

    assert_contains "$output" '--vm-bytes 384M'
}

test_vm_allocation_respects_cgroup_v2_ancestor_limit() {
    local output

    mkdir -p "$TEST_TMP/proc/self" "$TEST_TMP/cgroup/parent/leaf"
    printf 'MemAvailable:    8388608 kB\n' > "$TEST_TMP/proc/meminfo"
    printf '0::/parent/leaf\n' > "$TEST_TMP/proc/self/cgroup"
    printf 'max\n' > "$TEST_TMP/cgroup/parent/leaf/memory.max"
    printf '134217728\n' > "$TEST_TMP/cgroup/parent/leaf/memory.current"
    printf '1073741824\n' > "$TEST_TMP/cgroup/parent/memory.max"
    printf '268435456\n' > "$TEST_TMP/cgroup/parent/memory.current"

    output=$(STRESS_UV_PROC_ROOT="$TEST_TMP/proc" \
        STRESS_UV_CGROUP_ROOT="$TEST_TMP/cgroup" \
        "$HARNESS" memory-vm --dry-run --cpu-list 0-1 --memory-percent 50)

    assert_contains "$output" '--vm-bytes 384M'
}

test_vm_allocation_respects_cgroup_v1_ancestor_limit() {
    local output

    mkdir -p "$TEST_TMP/proc/self" "$TEST_TMP/cgroup/memory/parent/leaf"
    printf 'MemAvailable:    8388608 kB\n' > "$TEST_TMP/proc/meminfo"
    printf '5:memory:/parent/leaf\n' > "$TEST_TMP/proc/self/cgroup"
    printf '9223372036854771712\n' > "$TEST_TMP/cgroup/memory/parent/leaf/memory.limit_in_bytes"
    printf '134217728\n' > "$TEST_TMP/cgroup/memory/parent/leaf/memory.usage_in_bytes"
    printf '1073741824\n' > "$TEST_TMP/cgroup/memory/parent/memory.limit_in_bytes"
    printf '268435456\n' > "$TEST_TMP/cgroup/memory/parent/memory.usage_in_bytes"

    output=$(STRESS_UV_PROC_ROOT="$TEST_TMP/proc" \
        STRESS_UV_CGROUP_ROOT="$TEST_TMP/cgroup" \
        "$HARNESS" memory-vm --dry-run --cpu-list 0-1 --memory-percent 50)

    assert_contains "$output" '--vm-bytes 384M'
}

test_report_marks_interrupted_run_incomplete() {
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=RUNNING\nmode=cpu\nstage=cpu-transition\n' > "$TEST_TMP/run/state"

    output=$("$HARNESS" report "$TEST_TMP/run")
    assert_contains "$output" 'Result: INCOMPLETE'
    assert_contains "$output" 'Last stage: cpu-transition'
}

test_report_fails_on_hardware_error() {
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/run/state"
    printf 'stress-ng exit status: 0\n' > "$TEST_TMP/run/stages.tsv"
    printf 'mce: [Hardware Error]: Machine check events logged\n' > "$TEST_TMP/run/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/run")
    assert_contains "$output" 'Result: FAIL'
    assert_contains "$output" 'kernel hardware error'
}

test_report_rejects_nonzero_stress_exit() {
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/run/state"
    printf 'cpu-sustained\t2\tFAIL\n' > "$TEST_TMP/run/stages.tsv"
    : > "$TEST_TMP/run/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/run")
    assert_contains "$output" 'Result: FAIL'
    assert_contains "$output" 'stage failure'
}

test_report_fails_on_logged_verification_error() {
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=COMPLETE\nmode=memory\nstage=complete\n' > "$TEST_TMP/run/state"
    printf 'memory-vm\t0\tPASS\n' > "$TEST_TMP/run/stages.tsv"
    printf 'stress-ng: fail: vm: checksum verification failed\n' > "$TEST_TMP/run/memory-vm.log"
    printf 'kernel: test window complete\n' > "$TEST_TMP/run/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/run")
    assert_contains "$output" 'Result: FAIL'
    assert_contains "$output" 'stress log verification error'
}

test_report_treats_unsupported_stressor_as_inconclusive() {
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=COMPLETE\nmode=memory\nstage=complete\n' > "$TEST_TMP/run/state"
    printf 'memory-cache\t4\tERROR\n' > "$TEST_TMP/run/stages.tsv"
    printf 'kernel: test window complete\n' > "$TEST_TMP/run/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/run")
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_contains "$output" 'stage error'
}

test_report_rejects_missing_stage_records() {
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/run/state"
    printf 'cpu-sustained\n' > "$TEST_TMP/run/expected-stages"
    : > "$TEST_TMP/run/stages.tsv"
    printf 'kernel: test window complete\n' > "$TEST_TMP/run/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/run")
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_contains "$output" 'stage manifest incomplete'
}

test_report_rejects_duplicate_and_malformed_stage_records() {
    local output

    mkdir -p "$TEST_TMP/duplicate" "$TEST_TMP/malformed"
    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/duplicate/state"
    printf 'cpu-sustained\n' > "$TEST_TMP/duplicate/expected-stages"
    printf 'cpu-sustained\t0\tPASS\ncpu-sustained\t0\tPASS\n' \
        > "$TEST_TMP/duplicate/stages.tsv"
    printf 'kernel: clean\n' > "$TEST_TMP/duplicate/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/duplicate")
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_contains "$output" 'stage manifest incomplete'

    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/malformed/state"
    printf 'cpu-sustained\n' > "$TEST_TMP/malformed/expected-stages"
    printf 'cpu-sustained\tnot-a-status\tPASS\n' > "$TEST_TMP/malformed/stages.tsv"
    printf 'kernel: clean\n' > "$TEST_TMP/malformed/kernel.log"

    output=$("$HARNESS" report "$TEST_TMP/malformed")
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_contains "$output" 'stage manifest incomplete'
}

test_report_rejects_exit_verdict_contradictions() {
    local record
    local output

    mkdir -p "$TEST_TMP/run"
    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/run/state"
    printf 'cpu-sustained\n' > "$TEST_TMP/run/expected-stages"
    printf 'kernel: clean\n' > "$TEST_TMP/run/kernel.log"

    for record in $'cpu-sustained\t0\tFAIL' $'cpu-sustained\t0\tERROR' \
        $'cpu-sustained\t2\tPASS' $'cpu-sustained\t4\tPASS'; do
        printf '%s\n' "$record" > "$TEST_TMP/run/stages.tsv"
        output=$("$HARNESS" report "$TEST_TMP/run")
        assert_contains "$output" 'Result: INCONCLUSIVE'
        assert_contains "$output" 'stage manifest incomplete'
    done
}

test_report_exit_status_matches_verdict() {
    local exit_status

    mkdir -p "$TEST_TMP/pass" "$TEST_TMP/fail" "$TEST_TMP/incomplete"
    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/pass/state"
    printf 'cpu-sustained\n' > "$TEST_TMP/pass/expected-stages"
    printf 'cpu-sustained\t0\tPASS\n' > "$TEST_TMP/pass/stages.tsv"
    printf 'kernel: clean\n' > "$TEST_TMP/pass/kernel.log"
    "$HARNESS" report "$TEST_TMP/pass" >/dev/null
    assert_equals "$?" 0

    printf 'status=COMPLETE\nmode=cpu\nstage=complete\n' > "$TEST_TMP/fail/state"
    printf 'cpu-sustained\n' > "$TEST_TMP/fail/expected-stages"
    printf 'cpu-sustained\t2\tFAIL\n' > "$TEST_TMP/fail/stages.tsv"
    printf 'kernel: clean\n' > "$TEST_TMP/fail/kernel.log"
    "$HARNESS" report "$TEST_TMP/fail" >/dev/null
    exit_status=$?
    assert_equals "$exit_status" 1

    printf 'status=ABORTED\nmode=cpu\nstage=cpu-sustained\n' > "$TEST_TMP/incomplete/state"
    "$HARNESS" report "$TEST_TMP/incomplete" >/dev/null
    exit_status=$?
    assert_equals "$exit_status" 1
}

create_mock_tools() {
    mkdir -p "$TEST_TMP/bin"

    cat > "$TEST_TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -v ]]; then exit 0; fi
if [[ ${1:-} == -- ]]; then shift; fi
if [[ -n ${SUDO_FORK_DELAY:-} && " $* " == *' __root_supervisor '* ]]; then
    if [[ ${SUDO_CHILD_IGNORE_TERM:-0} == 1 ]]; then
        (trap '' TERM INT HUP; sleep "$SUDO_FORK_DELAY"; exec "$@") &
    else
        (sleep "$SUDO_FORK_DELAY"; exec "$@") &
    fi
    child_pid=$!
    child_pid_file=${SUDO_CHILD_PID_FILE:-}
    if [[ " $* " == *' turbostat '* && -n ${SUDO_TURBOSTAT_CHILD_PID_FILE:-} ]]; then
        child_pid_file=$SUDO_TURBOSTAT_CHILD_PID_FILE
    elif [[ " $* " == *' stress-ng '* && -n ${SUDO_STRESS_CHILD_PID_FILE:-} ]]; then
        child_pid_file=$SUDO_STRESS_CHILD_PID_FILE
    fi
    [[ -n $child_pid_file ]] && printf '%s\n' "$child_pid" > "$child_pid_file"
    wait "$child_pid"
    exit $?
fi
exec "$@"
EOF
cat > "$TEST_TMP/bin/stress-ng" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
    printf 'stress-ng mock 1.0\n'
    exit 0
fi
log_file=''
while (($#)); do
    if [[ $1 == --log-file ]]; then log_file=$2; shift 2; else shift; fi
done
if [[ ${STRESS_NG_BLOCK:-0} == 1 ]]; then
    printf '%s\n' "$$" > "$STRESS_NG_PID_FILE"
    trap 'printf "terminated\n" > "$STRESS_NG_TERM_FILE"; exit 143' TERM INT HUP
    while :; do sleep 1; done
fi
case $log_file in
    *benchmark-single-run-1.log) values='100 50' ;;
    *benchmark-single-run-2.log) values='102 51' ;;
    *benchmark-single-run-3.log) values='104 52' ;;
    *benchmark-multi-run-1.log) values='800 400' ;;
    *benchmark-multi-run-2.log) values='816 408' ;;
    *benchmark-multi-run-3.log) values='832 416' ;;
    *) values='' ;;
esac
if [[ -n $values && ${STRESS_NG_NO_METRICS:-0} != 1 ]]; then
    read -r add_rate mul_rate <<< "$values"
    {
        printf 'stress-ng: metrc: [1] vecfp %s float128add Mfp-ops/sec (harmonic mean of 1 instance)\n' "$add_rate"
        if [[ ${STRESS_NG_DUPLICATE_METRICS:-0} == 1 ]]; then
            printf 'stress-ng: metrc: [1] vecfp %s float128add Mfp-ops/sec (harmonic mean duplicate)\n' "$add_rate"
        fi
        if [[ ${STRESS_NG_INCONSISTENT_METRICS:-0} != 1 || $log_file != *run-2.log ]]; then
            printf 'stress-ng: metrc: [1] vecfp %s float128mul Mfp-ops/sec (harmonic mean of 1 instance)\n' "$mul_rate"
        fi
    } | tee "$log_file"
    exit "${STRESS_NG_EXIT:-0}"
fi
printf 'stress-ng mock completed\n' | tee "$log_file"
exit "${STRESS_NG_EXIT:-0}"
EOF
    cat > "$TEST_TMP/bin/turbostat" <<'EOF'
#!/usr/bin/env bash
output=''
while (($#)); do
    if [[ $1 == --out ]]; then output=$2; shift 2; else shift; fi
done
printf 'PkgWatt CoreTmp Avg_MHz\n20.0 55 4800\n' > "$output"
EOF
    cat > "$TEST_TMP/bin/sensors" <<'EOF'
#!/usr/bin/env bash
printf 'Package id 0: +55.0 C\n'
EOF
    cat > "$TEST_TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'kernel: stability test window complete\n'
EOF
    cat > "$TEST_TMP/bin/lscpu" <<'EOF'
#!/usr/bin/env bash
printf 'Model name: Mock CPU\nCPU(s): 1\n'
EOF
    cat > "$TEST_TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux mock 1.0 x86_64\n'
EOF
    chmod +x "$TEST_TMP/bin/"*
}

test_headless_stage_records_complete_pass() {
    local output
    local run_dirs
    local run_dir
    local run_mode

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" "$HARNESS" memory-cache \
        --yes --no-tui --cache-duration 1s --cpu-list 0 \
        --output "$TEST_TMP/runs")
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}
    run_mode=$(stat -c '%a' "$run_dir")

    assert_contains "$output" 'Result: PASS'
    assert_equals "$run_mode" 700
    [[ ! -e $run_dir/config ]] || fail 'run directory contains executable config'
    assert_file_contains "$run_dir/state" 'status=COMPLETE'
    assert_file_contains "$run_dir/stages.tsv" $'memory-cache\t0\tPASS'
    assert_file_contains "$run_dir/memory-cache.log" 'stress-ng mock completed'
    assert_file_contains "$run_dir/telemetry/turbostat.txt" 'PkgWatt'
}

test_headless_benchmark_writes_metrics_and_summary() {
    local output
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" "$HARNESS" benchmark \
        --yes --no-tui --benchmark-duration 1s --benchmark-warmup 1s \
        --benchmark-runs 3 --cpu-list 2 --output "$TEST_TMP/runs")
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_contains "$output" 'Result: PASS'
    assert_contains "$output" 'Benchmark summary:'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-single-run-3\t0\tPASS'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-multi-run-3\t0\tPASS'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-summary\t0\tPASS'
    assert_file_contains "$run_dir/benchmark.tsv" $'single\t1\tfloat128add Mfp-ops/sec\t100'
    assert_file_contains "$run_dir/benchmark.tsv" $'multi\t3\tfloat128mul Mfp-ops/sec\t416'
    assert_file_contains "$run_dir/benchmark-summary.tsv" $'single\tfloat128add Mfp-ops/sec\t102.000\t100.000\t104.000\t1.601'
    assert_file_contains "$run_dir/benchmark-summary.tsv" $'multi\tfloat128mul Mfp-ops/sec\t408.000\t400.000\t416.000\t1.601'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'cpu_list\t2'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'stress_ng_version\tstress-ng mock 1.0'
}

test_headless_benchmark_rejects_inconsistent_metric_sets() {
    local output
    local exit_status
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESS_NG_INCONSISTENT_METRICS=1 \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 1s \
        --benchmark-warmup 1s --benchmark-runs 3 --cpu-list 2 \
        --output "$TEST_TMP/runs")
    exit_status=$?
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_equals "$exit_status" 1
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-summary\t125\tERROR'
    [[ ! -e $run_dir/benchmark-summary.tsv ]] ||
        fail 'inconsistent metrics produced a benchmark summary'
}

test_headless_benchmark_rejects_missing_metrics() {
    local output
    local exit_status
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESS_NG_NO_METRICS=1 \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 1s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 2 \
        --output "$TEST_TMP/runs")
    exit_status=$?
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_equals "$exit_status" 1
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_contains "$output" 'stage error'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-single-run-1\t125\tERROR'
    assert_file_contains "$run_dir/benchmark-single-run-1.log" 'missing or invalid Mfp-ops/sec metrics'
    [[ ! -e $run_dir/benchmark-summary.tsv ]] ||
        fail 'missing metrics produced a benchmark summary'
}

test_headless_benchmark_rejects_duplicate_metrics() {
    local output
    local exit_status
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESS_NG_DUPLICATE_METRICS=1 \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 1s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 2 \
        --output "$TEST_TMP/runs")
    exit_status=$?
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_equals "$exit_status" 1
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-single-run-1\t125\tERROR'
    [[ ! -e $run_dir/benchmark-summary.tsv ]] ||
        fail 'duplicate metrics produced a benchmark summary'
}

write_benchmark_fixture() {
    local directory=$1
    local version=$2
    local single_add=$3
    local multi_add=$4
    local duration=${5:-60s}

    mkdir -p "$directory"
    {
        printf 'format_version\t1\n'
        printf 'cpu_list\t2\n'
        printf 'single_cpu\t2\n'
        printf 'online_cpu_list\t0-3\n'
        printf 'stress_ng_version\t%s\n' "$version"
        printf 'benchmark_duration\t%s\n' "$duration"
        printf 'benchmark_warmup\t15s\n'
        printf 'benchmark_runs\t3\n'
    } > "$directory/benchmark-context.tsv"
    {
        printf 'scope\tmetric\tmedian_mfp_ops_per_sec\tmin\tmax\tcv_percent\n'
        printf 'single\tfloat128add Mfp-ops/sec\t%s\t%s\t%s\t1.000\n' \
            "$single_add" "$single_add" "$single_add"
        printf 'multi\tfloat128add Mfp-ops/sec\t%s\t%s\t%s\t1.000\n' \
            "$multi_add" "$multi_add" "$multi_add"
    } > "$directory/benchmark-summary.tsv"
}

test_compare_reports_metric_deltas() {
    local output

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate")

    assert_contains "$output" $'scope\tmetric\tbaseline\tcandidate\tdelta_percent'
    assert_contains "$output" $'single\tfloat128add Mfp-ops/sec\t100.000\t105.000\t+5.000'
    assert_contains "$output" $'multi\tfloat128add Mfp-ops/sec\t800.000\t760.000\t-5.000'
}

test_compare_rejects_incompatible_context() {
    local output
    local exit_status

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 2.0' 105 760

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'stress-ng versions differ'
}

test_compare_rejects_different_benchmark_protocols() {
    local output
    local exit_status

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800 60s
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760 30s

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'benchmark protocols differ'
}

test_compare_rejects_duplicate_context_keys() {
    local output
    local exit_status

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760
    printf 'stress_ng_version\tstress-ng conflicting 2.0\n' >> \
        "$TEST_TMP/candidate/benchmark-context.tsv"

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'candidate benchmark context is missing or invalid: stress_ng_version'
}

test_compare_rejects_invalid_summary_contract() {
    local output
    local exit_status
    local directory

    for directory in "$TEST_TMP/baseline" "$TEST_TMP/candidate"; do
        write_benchmark_fixture "$directory" 'stress-ng mock 1.0' 100 800
        {
            printf 'scope\tmetric\tmedian_mfp_ops_per_sec\tmin\tmax\tcv_percent\n'
            printf 'single\tfloat128add Mfp-ops/sec\t100\tBROKEN\t104\t1.0\n'
            printf 'multi\tfloat128add Mfp-ops/sec\t800\t790\t810\tBROKEN\n'
        } > "$directory/benchmark-summary.tsv"
    done

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'benchmark summaries are malformed or metric sets differ'
}

test_compare_rejects_disjoint_scope_metrics() {
    local output
    local exit_status
    local directory

    for directory in "$TEST_TMP/baseline" "$TEST_TMP/candidate"; do
        write_benchmark_fixture "$directory" 'stress-ng mock 1.0' 100 800
        {
            printf 'scope\tmetric\tmedian_mfp_ops_per_sec\tmin\tmax\tcv_percent\n'
            printf 'single\tfloat128add Mfp-ops/sec\t100\t99\t101\t1.0\n'
            printf 'multi\tfloat128mul Mfp-ops/sec\t800\t790\t810\t1.0\n'
        } > "$directory/benchmark-summary.tsv"
    done

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'benchmark summaries are malformed or metric sets differ'
}

test_headless_stage_propagates_stressor_failure() {
    local output
    local exit_status

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESS_NG_EXIT=2 \
        "$HARNESS" cpu-sustained --yes --no-tui --cpu-duration 1s \
        --cpu-list 0 --output "$TEST_TMP/runs")
    exit_status=$?

    assert_equals "$exit_status" 1
    assert_contains "$output" 'Result: FAIL'
    assert_contains "$output" 'stage failure'
}

test_signal_stops_stressor_and_marks_run_aborted() {
    local harness_pid
    local stress_pid
    local run_dirs
    local run_dir
    local stress_was_alive=0

    create_mock_tools
    PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        STRESS_NG_BLOCK=1 \
        STRESS_NG_PID_FILE="$TEST_TMP/stress.pid" \
        STRESS_NG_TERM_FILE="$TEST_TMP/stress.term" \
        "$HARNESS" cpu-sustained --yes --no-tui --cpu-duration 1s \
        --cpu-list 0 --output "$TEST_TMP/runs" \
        > "$TEST_TMP/harness.out" 2>&1 &
    harness_pid=$!

    if ! wait_for_file "$TEST_TMP/stress.pid"; then
        kill -KILL "$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
        fail 'mock stressor did not start'
        return
    fi
    stress_pid=$(< "$TEST_TMP/stress.pid")
    kill -TERM "$harness_pid"
    if ! wait_for_exit "$harness_pid"; then
        fail 'harness did not finish signal cleanup'
        kill -KILL "$harness_pid" 2>/dev/null || true
    fi
    wait "$harness_pid" 2>/dev/null || true

    if kill -0 "$stress_pid" 2>/dev/null; then
        stress_was_alive=1
        kill -TERM "$stress_pid" 2>/dev/null || true
    fi
    kill -KILL "$stress_pid" 2>/dev/null || true

    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}
    assert_equals "$stress_was_alive" 0
    [[ -f $TEST_TMP/stress.term ]] || fail 'mock stressor did not receive termination signal'
    assert_file_contains "$run_dir/state" 'status=ABORTED'
}

test_signal_during_sudo_handoff_stops_delayed_child() {
    local harness_pid
    local stress_child_pid
    local turbostat_child_pid
    local stress_child_was_alive=0
    local turbostat_child_was_alive=0
    local run_dirs
    local run_dir

    create_mock_tools
    PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        SUDO_FORK_DELAY=5 \
        SUDO_CHILD_IGNORE_TERM=1 \
        SUDO_STRESS_CHILD_PID_FILE="$TEST_TMP/stress-sudo-child.pid" \
        SUDO_TURBOSTAT_CHILD_PID_FILE="$TEST_TMP/turbostat-sudo-child.pid" \
        "$HARNESS" cpu-sustained --yes --no-tui --cpu-duration 1s \
        --cpu-list 0 --output "$TEST_TMP/runs" \
        > "$TEST_TMP/handoff.out" 2>&1 &
    harness_pid=$!

    if ! wait_for_file "$TEST_TMP/stress-sudo-child.pid" ||
        ! wait_for_file "$TEST_TMP/turbostat-sudo-child.pid"; then
        kill -KILL "$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
        fail 'delayed stress or turbostat sudo child did not start'
        return
    fi
    stress_child_pid=$(< "$TEST_TMP/stress-sudo-child.pid")
    turbostat_child_pid=$(< "$TEST_TMP/turbostat-sudo-child.pid")
    kill -TERM "$harness_pid"
    wait_for_exit "$harness_pid" || kill -KILL "$harness_pid" 2>/dev/null || true
    wait "$harness_pid" 2>/dev/null || true

    if kill -0 "$stress_child_pid" 2>/dev/null; then
        stress_child_was_alive=1
        kill -TERM "$stress_child_pid" 2>/dev/null || true
    fi
    if kill -0 "$turbostat_child_pid" 2>/dev/null; then
        turbostat_child_was_alive=1
        kill -TERM "$turbostat_child_pid" 2>/dev/null || true
    fi
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}
    assert_equals "$stress_child_was_alive" 0
    assert_equals "$turbostat_child_was_alive" 0
    assert_file_contains "$run_dir/state" 'status=ABORTED'
}

test_real_sudo_cleanup_crosses_privilege_boundary_when_enabled() {
    local output

    [[ ${STRESS_UV_TEST_ROOT_CLEANUP:-0} == 1 ]] || return 0
    sudo -n true 2>/dev/null || {
        fail 'STRESS_UV_TEST_ROOT_CLEANUP=1 requires cached passwordless sudo'
        return
    }

    output=$(bash -c '
        source "$1"
        test_dir=$2
        outer_file=$test_dir/root-outer.pid
        inner_file=$test_dir/root-inner.pid
        child_file=$test_dir/root-child.pid
        : > "$outer_file"
        : > "$inner_file"
        setsid "$SCRIPT_PATH" __privileged_supervisor "$outer_file" "$inner_file" \
            bash -c '\''
                printf "%s\n" "$$" > "$1"
                trap "" INT TERM HUP
                while :; do sleep 1; done
            '\'' stress-uv-root-child "$child_file" &
        wrapper_pid=$!
        for ((attempt = 0; attempt < 100; attempt++)); do
            [[ -s $child_file ]] && break
            sleep 0.02
        done
        [[ -s $child_file ]] || exit 2
        read -r child_pid < "$child_file"
        while read -r key real_uid rest; do
            [[ $key == Uid: ]] && break
        done < "/proc/$child_pid/status"
        printf "root_uid=%s\n" "$real_uid"
        terminate_supervised_command "$wrapper_pid" "$outer_file" "$inner_file"
        if kill -0 "$child_pid" 2>/dev/null; then
            sudo -n kill -KILL "$child_pid" 2>/dev/null || true
            printf "child=leaked\n"
            exit 3
        fi
        printf "child=stopped\n"
    ' stress-uv-test "$HARNESS" "$TEST_TMP")

    assert_contains "$output" 'root_uid=0'
    assert_contains "$output" 'child=stopped'
}

test_process_identity_rejects_zombies_and_pid_reuse() {
    local output

    output=$(bash -c '
        source "$1"
        PROC_ROOT=$2
        mkdir -p "$PROC_ROOT/$$"
        write_stat() {
            local state=$1
            local starttime=$2
            local values=()
            local index
            for ((index = 4; index <= 21; index++)); do values+=(1); done
            printf "%s (mock process) %s %s %s\n" \
                "$$" "$state" "${values[*]}" "$starttime" > "$PROC_ROOT/$$/stat"
        }
        write_stat R 123
        process_matches_identity "$$" 123 && printf "matching=alive\n"
        write_stat Z 123
        process_matches_identity "$$" 123 || printf "zombie=dead\n"
        write_stat R 124
        process_matches_identity "$$" 123 || printf "reused=dead\n"

        kill() { printf "%s\n" "$*" >> "$PROC_ROOT/signals"; }
        printf "%s %s\n" "$$" 123 > "$PROC_ROOT/stale-record"
        signal_recorded_group TERM "$PROC_ROOT/stale-record" 0
        [[ ! -e $PROC_ROOT/signals ]] && printf "stale=skipped\n"
        printf "%s %s\n" "$$" 124 > "$PROC_ROOT/current-record"
        signal_recorded_group TERM "$PROC_ROOT/current-record" 0
        [[ -s $PROC_ROOT/signals ]] && printf "current=signaled\n"
    ' stress-uv-test "$HARNESS" "$TEST_TMP/proc")

    assert_contains "$output" 'matching=alive'
    assert_contains "$output" 'zombie=dead'
    assert_contains "$output" 'reused=dead'
    assert_contains "$output" 'stale=skipped'
    assert_contains "$output" 'current=signaled'
}

test_launcher_detach_marker_allows_worker_to_continue() {
    local output

    mkdir -p "$TEST_TMP/run"
    output=$(bash -c '
        source "$1"
        RUN_DIR=$2
        LAUNCHER_PID=$$
        LAUNCHER_STARTTIME=0
        : > "$RUN_DIR/launcher-detached"
        watch_launcher
        printf "detached=continues\n"
    ' stress-uv-test "$HARNESS" "$TEST_TMP/run")
    assert_contains "$output" 'detached=continues'
}

test_tmux_setup_failure_rolls_back_session() {
    local command
    local output
    local run_dirs
    local run_dir

    create_mock_tools
    cat > "$TEST_TMP/bin/s-tui" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
    new-session) printf 'mock:1\n'; exit 0 ;;
    display-message) printf '%%0\n'; exit 0 ;;
    split-window)
        count=0
        [[ -r $TMUX_SPLIT_COUNT_FILE ]] && read -r count < "$TMUX_SPLIT_COUNT_FILE"
        count=$((count + 1))
        printf '%s\n' "$count" > "$TMUX_SPLIT_COUNT_FILE"
        if (( count == 1 )); then printf '%%1\n'; exit 0; fi
        exit 1
        ;;
    kill-session) printf 'killed\n' > "$TMUX_KILL_FILE"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$TEST_TMP/bin/s-tui" "$TEST_TMP/bin/tmux"
    printf -v command '%q ' env \
        "PATH=$TEST_TMP/bin:/usr/bin:/bin" \
        "TMUX_KILL_FILE=$TEST_TMP/tmux.killed" \
        "TMUX_SPLIT_COUNT_FILE=$TEST_TMP/tmux.split-count" \
        "$HARNESS" cpu-sustained --yes --cpu-duration 1s --cpu-list 0 \
        --output "$TEST_TMP/runs"

    output=$(script -qec "${command% }" /dev/null 2>&1)
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_contains "$output" 'tmux setup failed: create journal pane'
    [[ -f $TEST_TMP/tmux.killed ]] || fail 'partial tmux session was not killed'
    assert_file_contains "$run_dir/state" 'status=ABORTED'
}

test_tmux_benchmark_supports_nonzero_window_and_pane_base_indices() {
    local command
    local output

    create_mock_tools
    mkdir -m 700 "$TEST_TMP/tmux"
    cat > "$TEST_TMP/bin/s-tui" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then printf 's-tui mock 1.0\n'; exit 0; fi
trap 'exit 0' INT TERM HUP
while :; do sleep 1; done
EOF
    chmod +x "$TEST_TMP/bin/s-tui"
    printf 'set-option -g base-index 3\nset-window-option -g pane-base-index 7\n' \
        > "$TEST_TMP/tmux.conf"
    PATH="$TEST_TMP/bin:/usr/bin:/bin" TERM=xterm-256color TMUX= \
        TMUX_TMPDIR="$TEST_TMP/tmux" \
        tmux -f "$TEST_TMP/tmux.conf" new-session -d -s bootstrap 'sleep 30'
    printf -v command '%q ' env \
        "PATH=$TEST_TMP/bin:/usr/bin:/bin" \
        "TMUX=" \
        "TMUX_TMPDIR=$TEST_TMP/tmux" \
        "TERM=xterm-256color" \
        "$HARNESS" benchmark --yes --benchmark-duration 1s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 0 \
        --output "$TEST_TMP/runs"

    output=$(TERM=xterm-256color TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" \
        script -qec "${command% }" /dev/null 2>&1)
    TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" tmux kill-server 2>/dev/null || true

    assert_not_contains "$output" 'tmux setup failed'
    assert_contains "$output" 'Result: PASS'
}

test_signal_to_tmux_launcher_aborts_session_and_stressor() {
    local command
    local script_pid
    local launcher_pid
    local stress_pid
    local run_dirs
    local run_dir
    local timestamp
    local session
    local session_stopped=0
    local stress_stopped=0
    local state_aborted=0
    local launch_output
    local launcher_alive=0
    local state_snapshot

    create_mock_tools
    mkdir -m 700 "$TEST_TMP/tmux"
    cat > "$TEST_TMP/bin/s-tui" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
    printf 's-tui mock 1.0\n'
    exit 0
fi
trap 'exit 0' INT TERM HUP
while :; do sleep 1; done
EOF
    chmod +x "$TEST_TMP/bin/s-tui"
    printf -v command '%q ' bash -c \
        'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
        stress-uv-launch "$TEST_TMP/launcher.pid" env \
        "PATH=$TEST_TMP/bin:/usr/bin:/bin" \
        "TMUX=" \
        "TMUX_TMPDIR=$TEST_TMP/tmux" \
        "TERM=xterm-256color" \
        STRESS_NG_BLOCK=1 \
        "STRESS_NG_PID_FILE=$TEST_TMP/stress.pid" \
        "STRESS_NG_TERM_FILE=$TEST_TMP/stress.term" \
        "$HARNESS" cpu-sustained --yes --cpu-duration 1s --cpu-list 0 \
        --output "$TEST_TMP/runs"

    TERM=xterm-256color TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" \
        script -qec "${command% }" /dev/null \
        > "$TEST_TMP/tmux-launcher.out" 2>&1 &
    script_pid=$!
    if ! wait_for_file "$TEST_TMP/launcher.pid" || ! wait_for_file "$TEST_TMP/stress.pid"; then
        kill -KILL "$script_pid" 2>/dev/null || true
        wait "$script_pid" 2>/dev/null || true
        launch_output=$(< "$TEST_TMP/tmux-launcher.out")
        launch_output=${launch_output//$'\n'/ }
        fail "tmux worker did not start: $launch_output"
        return
    fi

    launcher_pid=$(< "$TEST_TMP/launcher.pid")
    stress_pid=$(< "$TEST_TMP/stress.pid")
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}
    timestamp=${run_dir##*/}
    timestamp=${timestamp%-cpu-sustained}
    session="stress-uv-${timestamp}-${launcher_pid}"
    kill -TERM "$launcher_pid"

    TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" wait_for_tmux_exit "$session" && session_stopped=1
    wait_for_exit "$stress_pid" && stress_stopped=1
    wait_for_state "$run_dir/state" ABORTED && state_aborted=1
    kill -0 "$launcher_pid" 2>/dev/null && launcher_alive=1
    state_snapshot=$(< "$run_dir/state")
    state_snapshot=${state_snapshot//$'\n'/, }
    launch_output=$(< "$TEST_TMP/tmux-launcher.out")
    launch_output=${launch_output//$'\n'/ }

    TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" tmux kill-session -t "$session" 2>/dev/null || true
    kill -KILL "$script_pid" 2>/dev/null || true
    wait "$script_pid" 2>/dev/null || true
    kill -KILL "$stress_pid" 2>/dev/null || true

    [[ $session_stopped == 1 ]] ||
        fail "tmux session survived launcher signal; launcher_alive=$launcher_alive state=[$state_snapshot] output=[$launch_output]"
    [[ $stress_stopped == 1 ]] || fail 'stress process survived launcher signal'
    [[ $state_aborted == 1 ]] || fail "run was not marked ABORTED: $state_snapshot"
}

run_test 'help lists suites and stages' test_help_lists_suites_and_stages
run_test 'benchmark plan uses repeated vecfp runs' test_benchmark_dry_run_uses_vecfp_repetitions
run_test 'CPU plan is sequential and cycles each CPU' test_cpu_dry_run_is_sequential_and_cycles_each_cpu
run_test 'all plan runs CPU before memory' test_all_dry_run_orders_cpu_before_memory
run_test 'VM allocation respects cgroup v2 headroom' test_vm_allocation_respects_cgroup_v2_headroom
run_test 'VM allocation respects cgroup v1 headroom' test_vm_allocation_respects_cgroup_v1_headroom
run_test 'VM allocation respects cgroup v2 ancestor limit' test_vm_allocation_respects_cgroup_v2_ancestor_limit
run_test 'VM allocation respects cgroup v1 ancestor limit' test_vm_allocation_respects_cgroup_v1_ancestor_limit
run_test 'report detects interrupted runs' test_report_marks_interrupted_run_incomplete
run_test 'report detects kernel hardware errors' test_report_fails_on_hardware_error
run_test 'report rejects nonzero stress exits' test_report_rejects_nonzero_stress_exit
run_test 'report detects logged verification errors' test_report_fails_on_logged_verification_error
run_test 'report separates unsupported stressors from instability' test_report_treats_unsupported_stressor_as_inconclusive
run_test 'report rejects missing stage records' test_report_rejects_missing_stage_records
run_test 'report rejects duplicate and malformed stage records' test_report_rejects_duplicate_and_malformed_stage_records
run_test 'report rejects exit and verdict contradictions' test_report_rejects_exit_verdict_contradictions
run_test 'report exit status matches verdict' test_report_exit_status_matches_verdict
run_test 'headless stage records a complete passing run' test_headless_stage_records_complete_pass
run_test 'headless benchmark writes metrics and summary' test_headless_benchmark_writes_metrics_and_summary
run_test 'headless benchmark rejects inconsistent metric sets' test_headless_benchmark_rejects_inconsistent_metric_sets
run_test 'headless benchmark rejects missing metrics' test_headless_benchmark_rejects_missing_metrics
run_test 'headless benchmark rejects duplicate metrics' test_headless_benchmark_rejects_duplicate_metrics
run_test 'compare reports benchmark metric deltas' test_compare_reports_metric_deltas
run_test 'compare rejects incompatible benchmark context' test_compare_rejects_incompatible_context
run_test 'compare rejects different benchmark protocols' test_compare_rejects_different_benchmark_protocols
run_test 'compare rejects duplicate context keys' test_compare_rejects_duplicate_context_keys
run_test 'compare rejects invalid summary contract' test_compare_rejects_invalid_summary_contract
run_test 'compare rejects disjoint scope metrics' test_compare_rejects_disjoint_scope_metrics
run_test 'headless stage propagates stressor failure' test_headless_stage_propagates_stressor_failure
run_test 'signals stop stressor and mark run aborted' test_signal_stops_stressor_and_marks_run_aborted
run_test 'signals during sudo handoff stop delayed child' test_signal_during_sudo_handoff_stops_delayed_child
run_test 'real sudo cleanup crosses privilege boundary when enabled' test_real_sudo_cleanup_crosses_privilege_boundary_when_enabled
run_test 'process identity rejects zombies and PID reuse' test_process_identity_rejects_zombies_and_pid_reuse
run_test 'launcher detach marker lets worker continue' test_launcher_detach_marker_allows_worker_to_continue
run_test 'tmux setup failure rolls back session' test_tmux_setup_failure_rolls_back_session
run_test 'tmux benchmark supports nonzero base indices' test_tmux_benchmark_supports_nonzero_window_and_pane_base_indices
run_test 'signals to tmux launcher abort session and stressor' test_signal_to_tmux_launcher_aborts_session_and_stressor

printf '1..%d\n' "$TESTS_RUN"
exit "$TESTS_FAILED"
