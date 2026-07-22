#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HARNESS="$ROOT_DIR/stress-uv"
TEST_TMP=""
TESTS_RUN=0
TESTS_FAILED=0

setup() {
    TEST_TMP=$(mktemp -d)
    export STRESS_UV_SYS_CPU_ROOT="$TEST_TMP/sys"
}

teardown() {
    if [[ ${STRESS_UV_KEEP_TEST_TMP:-0} == 1 ]]; then
        printf '# kept test directory: %s\n' "$TEST_TMP"
        return
    fi
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
    local stat
    local stat_tail

    for ((attempt = 0; attempt < 300; attempt++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        if [[ -r /proc/$pid/stat ]]; then
            stat=$(< "/proc/$pid/stat")
            stat_tail=${stat##*) }
            [[ ${stat_tail%% *} == Z ]] && return 0
        fi
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

    if [[ -n ${STRESS_UV_TEST_FILTER:-} && $name != *"$STRESS_UV_TEST_FILTER"* ]]; then
        return
    fi
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
    assert_contains "$output" 'memory-stressapptest'
    assert_contains "$output" 'memory-memtester'
    assert_contains "$output" 'memory-vm'
    assert_contains "$output" 'benchmark'
    assert_contains "$output" '--benchmark-duration'
    assert_contains "$output" '--benchmark-warmup'
    assert_contains "$output" '--benchmark-runs'
    assert_contains "$output" '--stressapptest-duration'
    assert_contains "$output" '--memtester-loops'
    assert_contains "$output" 'compare BASELINE_RUN CANDIDATE_RUN'
    assert_contains "$output" 'report RUN_DIR'
}

test_benchmark_dry_run_uses_vecfp_repetitions() {
    local output

    mkdir -p "$STRESS_UV_SYS_CPU_ROOT"
    printf '2-3\n' > "$STRESS_UV_SYS_CPU_ROOT/online"
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
    assert_contains "$output" '--vecfp 2 --vecfp-method all --taskset 2\,3 --timeout 30s'
    assert_contains "$output" '--metrics'
    assert_not_contains "$output" '--metrics-brief'
}

test_benchmark_rejects_duration_too_short_for_frequency_evidence() {
    local output
    local exit_status

    mkdir -p "$STRESS_UV_SYS_CPU_ROOT"
    printf '2\n' > "$STRESS_UV_SYS_CPU_ROOT/online"

    output=$("$HARNESS" benchmark --dry-run --cpu-list 2 \
        --benchmark-duration 4.9s 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'benchmark duration must be at least 5s for frequency evidence'
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
        'STAGE memory-stressapptest' \
        'STAGE memory-memtester' \
        'STAGE memory-vm'
    assert_contains "$output" 'MEMORY target=85%'
    assert_contains "$output" '--vm-bytes '
    assert_not_contains "$output" '--vm-bytes 85%'
}

test_memory_dry_run_uses_stressapptest_and_memtester_sequentially() {
    local output

    mkdir -p "$TEST_TMP/proc/self"
    printf 'MemAvailable:    1048576 kB\n' > "$TEST_TMP/proc/meminfo"

    output=$(STRESS_UV_PROC_ROOT="$TEST_TMP/proc" \
        "$HARNESS" memory --dry-run --cpu-list 0-1 --memory-percent 50 \
        --cache-duration 1s --stressapptest-duration 30s \
        --memtester-loops 2 --vm-duration 1s)

    assert_order "$output" \
        'STAGE memory-cache' \
        'STAGE memory-stressapptest' \
        'STAGE memory-memtester' \
        'STAGE memory-vm'
    assert_contains "$output" 'stressapptest -s 30 -M 512 -m 2 -W --max_errors 1'
    assert_contains "$output" 'memtester 512M 2'
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
    mkdir -p "$TEST_TMP/bin" "$STRESS_UV_SYS_CPU_ROOT/cpu2/topology"
    printf '2\n' > "$STRESS_UV_SYS_CPU_ROOT/online"
    printf '0\n' > "$STRESS_UV_SYS_CPU_ROOT/cpu2/topology/physical_package_id"
    printf '1\n' > "$STRESS_UV_SYS_CPU_ROOT/cpu2/topology/core_id"

    cat > "$TEST_TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
original_args=$*
noninteractive=0
validate=0
askpass=0
while (($#)); do
    case $1 in
        -A) askpass=1; shift ;;
        -n) noninteractive=1; shift ;;
        -v) validate=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
if [[ -n ${SUDO_COMMAND_LOG:-} ]]; then
    printf 'validate=%s noninteractive=%s askpass=%s args=%s\n' \
        "$validate" "$noninteractive" "$askpass" "$original_args" >> "$SUDO_COMMAND_LOG"
fi
if (( validate == 1 && askpass == 1 )) && [[ ${SUDO_ASKPASS_FAIL:-0} == 1 ]]; then
    exit 1
fi
if [[ ${SUDO_TTY_TICKETS:-0} == 1 ]]; then
    tty_key=$(ps -o tty= -p "$$" | tr -d ' ')
    [[ -n $tty_key && $tty_key != '?' ]] || tty_key=none
    marker="$SUDO_TIMESTAMP_DIR/${tty_key//\//_}"
    if (( validate == 1 )); then
        if (( noninteractive == 0 )); then
            [[ $tty_key != none ]] || exit 1
            : > "$marker"
            printf 'validate tty=%s auth=created\n' "$tty_key" >> "$SUDO_LOG"
            exit 0
        fi
        if [[ -e $marker ]]; then
            printf 'validate tty=%s auth=hit\n' "$tty_key" >> "$SUDO_LOG"
            exit 0
        fi
        printf 'validate tty=%s auth=miss\n' "$tty_key" >> "$SUDO_LOG"
        exit 1
    fi
    if [[ ! -e $marker ]]; then
        printf 'command tty=%s noninteractive=%s auth=miss args=%s\n' \
            "$tty_key" "$noninteractive" "$*" >> "$SUDO_LOG"
        printf 'sudo: a password is required\n' >&2
        exit 1
    fi
    printf 'command tty=%s noninteractive=%s auth=hit args=%s\n' \
        "$tty_key" "$noninteractive" "$*" >> "$SUDO_LOG"
elif (( validate == 1 )); then
    exit 0
fi
if [[ ${SUDO_REJECT_AFTER_BROKER:-0} == 1 && -e ${SUDO_BROKER_MARKER:-/nonexistent} &&
    " $* " != *' __broker '* ]]; then
    printf 'sudo: cached credential expired\n' >&2
    exit 1
fi
if [[ ${SUDO_REJECT_AFTER_BROKER:-0} == 1 && " $* " == *' __broker '* ]]; then
    : > "$SUDO_BROKER_MARKER"
fi
exec "$@"
EOF
    cat > "$TEST_TMP/bin/stress-ng" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then
    printf 'stress-ng mock 1.0\n'
    exit 0
fi
[[ -n ${STRESS_NG_COMMAND_LOG:-} ]] && printf '%s\n' "$*" >> "$STRESS_NG_COMMAND_LOG"
log_file=''
while (($#)); do
    if [[ $1 == --log-file ]]; then log_file=$2; shift 2; else shift; fi
done
if [[ ${STRESS_NG_BLOCK:-0} == 1 ]]; then
    printf '%s\n' "$$" > "$STRESS_NG_PID_FILE"
    trap 'printf "terminated\n" > "$STRESS_NG_TERM_FILE"; exit 143' TERM INT HUP
    while :; do sleep 1; done
fi
case ${STRESS_UV_STAGE_LABEL:-$log_file} in
    *benchmark-single-run-1*) values='100 50' ;;
    *benchmark-single-run-2*) values='102 51' ;;
    *benchmark-single-run-3*) values='104 52' ;;
    *benchmark-multi-run-1*) values='800 400' ;;
    *benchmark-multi-run-2*) values='816 408' ;;
    *benchmark-multi-run-3*) values='832 416' ;;
    *) values='' ;;
esac
if [[ -n $values && ${STRESS_NG_NO_METRICS:-0} != 1 ]]; then
    read -r add_rate mul_rate <<< "$values"
    {
        printf 'stress-ng: metrc: [1] vecfp %s float128add Mfp-ops/sec (harmonic mean of 1 instance)\n' "$add_rate"
        if [[ ${STRESS_NG_DUPLICATE_METRICS:-0} == 1 ]]; then
            printf 'stress-ng: metrc: [1] vecfp %s float128add Mfp-ops/sec (harmonic mean duplicate)\n' "$add_rate"
        fi
        if [[ ${STRESS_NG_INCONSISTENT_METRICS:-0} != 1 ||
            ${STRESS_UV_STAGE_LABEL:-$log_file} != *run-2* ]]; then
            printf 'stress-ng: metrc: [1] vecfp %s float128mul Mfp-ops/sec (harmonic mean of 1 instance)\n' "$mul_rate"
        fi
    } | tee "$log_file"
    exit "${STRESS_NG_EXIT:-0}"
fi
printf 'stress-ng mock completed\n' | tee "$log_file"
exit "${STRESS_NG_EXIT:-0}"
EOF
    cat > "$TEST_TMP/bin/stressapptest" <<'EOF'
#!/usr/bin/env bash
printf 'stressapptest mock args:'
printf ' %s' "$@"
printf '\n'
case ${STRESSAPPTEST_RESULT:-} in
    hardware) printf 'Status: FAIL - test discovered HW problems\n' ;;
    procedural) printf 'Status: FAIL - test encountered procedural errors\n' ;;
esac
exit "${STRESSAPPTEST_EXIT:-0}"
EOF
    cat > "$TEST_TMP/bin/memtester" <<'EOF'
#!/usr/bin/env bash
printf 'memtester mock args:'
printf ' %s' "$@"
printf '\n'
exit "${MEMTESTER_EXIT:-0}"
EOF
    cat > "$TEST_TMP/bin/base64" <<'EOF'
#!/usr/bin/env bash
decode=0
for argument in "$@"; do
    [[ $argument == -d || $argument == --decode ]] && decode=1
done
if (( decode == 1 )) && [[ ${BASE64_DECODE_FAIL:-0} == 1 ]]; then
    printf 'partial evidence'
    exit 1
fi
if (( decode == 0 )) && [[ ${BASE64_ENCODE_FAIL:-0} == 1 && " $* " == *stage.log* ]]; then
    encoded=$(/usr/bin/base64 "$@")
    printf '%s\n' "${encoded:0:8}"
    exit 1
fi
exec /usr/bin/base64 "$@"
EOF
    cat > "$TEST_TMP/bin/turbostat" <<'EOF'
#!/usr/bin/env bash
original_args=$*
output=''
cpu_set=''
while (($#)); do
    case $1 in
        --out) output=$2; shift 2 ;;
        --cpu) cpu_set=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n ${TURBOSTAT_COMMAND_LOG:-} ]] && printf '%s\n' "$original_args" >> "$TURBOSTAT_COMMAND_LOG"
if [[ $output == *benchmark-frequency-* ]]; then
    [[ ${TURBOSTAT_FREQUENCY_FAIL:-0} == 1 ]] && exit 1
    case $output in
        *benchmark-single-run-*) bzy_base=4500; avg_base=4400 ;;
        *benchmark-multi-run-*) bzy_base=4200; avg_base=4100 ;;
        *) exit 2 ;;
    esac
    : > "$output"
    for sample in 0 1 2 3 4; do
        printf 'Time_Of_Day_Seconds\tCPU\tAvg_MHz\tBusy%%\tBzy_MHz\n' >> "$output"
        printf '%s\t-\t%s\t99.%s\t%s\n' \
            "$((100 + sample))" "$((avg_base + sample * 10))" "$sample" \
            "$((bzy_base + sample * 10))" >> "$output"
        IFS=',' read -r -a cpus <<< "$cpu_set"
        for cpu in "${cpus[@]}"; do
            [[ $cpu == "${TURBOSTAT_DROP_CPU:-}" ]] && continue
            printf '%s\t%s\t%s\t99.%s\t%s\n' \
                "$((100 + sample))" "$cpu" "$((avg_base + sample * 10))" \
                "$sample" "$((bzy_base + sample * 10))" >> "$output"
        done
    done
    trap 'exit 0' INT TERM HUP
    while :; do sleep 1; done
fi
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

configure_two_mock_cpus() {
    mkdir -p "$STRESS_UV_SYS_CPU_ROOT/cpu3/topology"
    printf '2-3\n' > "$STRESS_UV_SYS_CPU_ROOT/online"
    printf '0\n' > "$STRESS_UV_SYS_CPU_ROOT/cpu3/topology/physical_package_id"
    printf '2\n' > "$STRESS_UV_SYS_CPU_ROOT/cpu3/topology/core_id"
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

test_headless_official_memory_stages_record_commands() {
    local output
    local run_dirs
    local run_dir
    local stressapp_log
    local stressapp_mib
    local memtester_log
    local memtester_mib

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" "$HARNESS" memory \
        --yes --no-tui --cache-duration 1s --stressapptest-duration 1s \
        --memtester-loops 1 --vm-duration 1s --memory-percent 1 \
        --cpu-list 0 --output "$TEST_TMP/runs")
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_contains "$output" 'Result: PASS'
    assert_file_contains "$run_dir/stages.tsv" $'memory-stressapptest\t0\tPASS'
    assert_file_contains "$run_dir/stages.tsv" $'memory-memtester\t0\tPASS'
    stressapp_log=$(< "$run_dir/memory-stressapptest.log")
    memtester_log=$(< "$run_dir/memory-memtester.log")
    [[ $stressapp_log =~ ^stressapptest\ mock\ args:\ -s\ 1\ -M\ ([0-9]+)\ -m\ 1\ -W\ --max_errors\ 1$ ]] ||
        fail 'stressapptest executed arguments were malformed'
    stressapp_mib=${BASH_REMATCH[1]}
    [[ $memtester_log =~ ^memtester\ mock\ args:\ ([0-9]+)M\ 1$ ]] ||
        fail 'memtester executed arguments were malformed'
    memtester_mib=${BASH_REMATCH[1]}
    (( stressapp_mib > 0 && memtester_mib > 0 )) || fail 'memory allocation was not positive'
}

test_official_memory_errors_are_failures() {
    local output
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESSAPPTEST_EXIT=1 \
        STRESSAPPTEST_RESULT=hardware \
        "$HARNESS" memory-stressapptest --yes --no-tui \
        --stressapptest-duration 1s --memory-percent 1 --cpu-list 0 \
        --output "$TEST_TMP/stressapp-runs")
    run_dirs=("$TEST_TMP/stressapp-runs"/*)
    run_dir=${run_dirs[0]}
    assert_contains "$output" 'Result: FAIL'
    assert_file_contains "$run_dir/stages.tsv" $'memory-stressapptest\t1\tFAIL'

    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESSAPPTEST_EXIT=1 \
        STRESSAPPTEST_RESULT=procedural \
        "$HARNESS" memory-stressapptest --yes --no-tui \
        --stressapptest-duration 1s --memory-percent 1 --cpu-list 0 \
        --output "$TEST_TMP/stressapp-procedural-runs")
    run_dirs=("$TEST_TMP/stressapp-procedural-runs"/*)
    run_dir=${run_dirs[0]}
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_file_contains "$run_dir/stages.tsv" $'memory-stressapptest\t1\tERROR'

    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" MEMTESTER_EXIT=4 \
        "$HARNESS" memory-memtester --yes --no-tui \
        --memtester-loops 1 --memory-percent 1 --cpu-list 0 \
        --output "$TEST_TMP/memtester-runs")
    run_dirs=("$TEST_TMP/memtester-runs"/*)
    run_dir=${run_dirs[0]}
    assert_contains "$output" 'Result: FAIL'
    assert_file_contains "$run_dir/stages.tsv" $'memory-memtester\t4\tFAIL'
}

test_idle_broker_exits_when_worker_dies() {
    local worker_pid
    local worker_starttime
    local broker_pid

    create_mock_tools
    mkfifo -m 600 "$TEST_TMP/broker-requests"
    sleep 30 &
    worker_pid=$!
    worker_starttime=$(awk '{print $22}' "/proc/$worker_pid/stat")
    PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        STRESS_UV_TEST_BROKER_TMP_PARENT="$TEST_TMP/broker-tmp" \
        "$HARNESS" __broker cpu 1s 1s 1s 1s 1 1 0 \
        '' '2026-01-01T00:00:00+00:00' 1s 1s 1 \
        "$worker_pid" "$worker_starttime" "$(id -u)" \
        "$TEST_TMP/broker-requests" 1s 1 > "$TEST_TMP/broker.out" 2>&1 &
    broker_pid=$!
    wait_for_file "$TEST_TMP/broker.out" || fail 'broker did not become ready'

    kill -KILL "$worker_pid"
    wait "$worker_pid" 2>/dev/null || true
    if ! wait_for_exit "$broker_pid"; then
        kill -KILL "$broker_pid" 2>/dev/null || true
        fail 'idle broker survived worker death'
    fi
    wait "$broker_pid" 2>/dev/null || true
}

test_malformed_shutdown_acknowledgement_forces_broker_stop() {
    local output

    output=$(bash -c '
        source "$1"
        sleep 30 &
        fake_pid=$!
        BROKER_PID=$fake_pid
        BROKER_STARTTIME=$(process_starttime "$fake_pid")
        exec {BROKER_IN_FD}>/dev/null
        exec {BROKER_OUT_FD}< <(printf "BAD\\t1\\n")
        stop_privileged_broker
        result=$?
        if process_is_running "$fake_pid"; then alive=1; else alive=0; fi
        printf "result=%s alive=%s\\n" "$result" "$alive"
        wait "$fake_pid" 2>/dev/null || true
    ' stress-uv-test "$HARNESS")

    assert_contains "$output" 'result=1 alive=0'
}

test_broker_teardown_does_not_signal_reused_pid() {
    local output

    output=$(bash -c '
        source "$1"
        unrelated_pid=$(bash -c "sleep 30 >/dev/null 2>&1 & printf %s \$!")
        BROKER_PID=$unrelated_pid
        BROKER_STARTTIME=$(( $(process_starttime "$unrelated_pid") + 1 ))
        BROKER_IN_FD=""
        BROKER_OUT_FD=""
        stop_privileged_broker >/dev/null 2>&1
        stop_result=$?
        if kill -0 "$unrelated_pid" 2>/dev/null; then stop_alive=1; else stop_alive=0; fi

        BROKER_PID=$unrelated_pid
        BROKER_STARTTIME=$(( $(process_starttime "$unrelated_pid") + 1 ))
        cancel_privileged_broker >/dev/null 2>&1
        if kill -0 "$unrelated_pid" 2>/dev/null; then cancel_alive=1; else cancel_alive=0; fi
        printf "stop=%s stop_alive=%s cancel_alive=%s\\n" \
            "$stop_result" "$stop_alive" "$cancel_alive"
        kill -TERM "$unrelated_pid" 2>/dev/null || true
    ' stress-uv-test "$HARNESS")

    assert_contains "$output" 'stop=1 stop_alive=1 cancel_alive=1'
}

test_headless_benchmark_writes_metrics_and_summary() {
    local output
    local run_dirs
    local run_dir

    create_mock_tools
    mkdir -p "$TEST_TMP/sys/cpu2" "$TEST_TMP/sys/cpufreq/policy2"
    ln -s "$TEST_TMP/sys/cpufreq/policy2" "$TEST_TMP/sys/cpu2/cpufreq"
    printf 'mock-driver\n' > "$TEST_TMP/sys/cpufreq/policy2/scaling_driver"
    printf 'performance\n' > "$TEST_TMP/sys/cpufreq/policy2/scaling_governor"
    printf '1000000\n' > "$TEST_TMP/sys/cpufreq/policy2/scaling_min_freq"
    printf '5000000\n' > "$TEST_TMP/sys/cpufreq/policy2/scaling_max_freq"
    printf '800000\n' > "$TEST_TMP/sys/cpufreq/policy2/cpuinfo_min_freq"
    printf '5200000\n' > "$TEST_TMP/sys/cpufreq/policy2/cpuinfo_max_freq"
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        STRESS_UV_SYS_CPU_ROOT="$TEST_TMP/sys" \
        TURBOSTAT_COMMAND_LOG="$TEST_TMP/turbostat-commands.log" \
        "$HARNESS" benchmark \
        --yes --no-tui --benchmark-duration 5s --benchmark-warmup 1s \
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
    assert_file_contains "$run_dir/benchmark-frequencies.tsv" \
        $'single\t1\t3\t102\t0\t1\t2\t4420\t99.2\t4520'
    assert_file_contains "$run_dir/benchmark-frequencies.tsv" \
        $'multi\t3\t4\t103\t0\t1\t2\t4130\t99.3\t4230'
    assert_file_contains "$run_dir/benchmark-frequency-summary.tsv" \
        $'single\t0\t1\t2\t4520.000\t4510.000\t4530.000\t4420.000\t99.200\t9'
    assert_file_contains "$run_dir/benchmark-frequency-summary.tsv" \
        $'multi\t0\t1\t2\t4220.000\t4210.000\t4230.000\t4120.000\t99.200\t9'
    assert_file_contains "$run_dir/benchmark-cpu-config.tsv" \
        $'2\tpolicy2\tmock-driver\tperformance\t1000000\t5000000\t800000\t5200000'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'cpu_list\t2'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'format_version\t2'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'stress_ng_version\tstress-ng mock 1.0'
    assert_file_contains "$TEST_TMP/turbostat-commands.log" '--interval 1 --cpu 2'
    assert_file_contains "$TEST_TMP/turbostat-commands.log" \
        '--show CPU,Avg_MHz,Busy%,Bzy_MHz --enable Time_Of_Day_Seconds'
}

test_headless_benchmark_uses_recorded_cpu_sets() {
    local output
    local run_dirs
    local run_dir

    create_mock_tools
    configure_two_mock_cpus
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        STRESS_NG_COMMAND_LOG="$TEST_TMP/stress-ng-commands.log" \
        TURBOSTAT_COMMAND_LOG="$TEST_TMP/turbostat-commands.log" \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 5s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 3 \
        --output "$TEST_TMP/runs")
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_contains "$output" 'Result: PASS'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'cpu_list\t3'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'single_cpu\t3'
    assert_file_contains "$run_dir/benchmark-context.tsv" $'online_cpu_list\t2,3'
    assert_file_contains "$TEST_TMP/stress-ng-commands.log" \
        '--vecfp 1 --vecfp-method all --taskset 3'
    assert_file_contains "$TEST_TMP/stress-ng-commands.log" \
        '--vecfp 2 --vecfp-method all --taskset 2,3'
    assert_file_contains "$TEST_TMP/turbostat-commands.log" '--cpu 3'
    assert_file_contains "$TEST_TMP/turbostat-commands.log" '--cpu 2,3'
    assert_file_contains "$run_dir/benchmark-cpu-config.tsv" $'2\tunavailable'
    assert_file_contains "$run_dir/benchmark-cpu-config.tsv" $'3\tunavailable'
    assert_file_contains "$run_dir/benchmark-frequency-summary.tsv" $'single\t0\t2\t3'
    assert_file_contains "$run_dir/benchmark-frequency-summary.tsv" $'multi\t0\t1\t2'
    assert_file_contains "$run_dir/benchmark-frequency-summary.tsv" $'multi\t0\t2\t3'
}

test_headless_benchmark_rejects_partial_cpu_frequency_evidence() {
    local output
    local exit_status
    local run_dirs
    local run_dir

    create_mock_tools
    configure_two_mock_cpus
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" TURBOSTAT_DROP_CPU=3 \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 5s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 2 \
        --output "$TEST_TMP/runs")
    exit_status=$?
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_equals "$exit_status" 1
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-multi-run-1\t125\tERROR'
    [[ ! -e $run_dir/benchmark-frequency-summary.tsv ]] ||
        fail 'partial CPU frequency evidence produced a benchmark summary'
}

test_headless_benchmark_rejects_inconsistent_metric_sets() {
    local output
    local exit_status
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" STRESS_NG_INCONSISTENT_METRICS=1 \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 5s \
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
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 5s \
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
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 5s \
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

test_headless_benchmark_requires_frequency_evidence() {
    local output
    local exit_status
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" TURBOSTAT_FREQUENCY_FAIL=1 \
        "$HARNESS" benchmark --yes --no-tui --benchmark-duration 5s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 2 \
        --output "$TEST_TMP/runs")
    exit_status=$?
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}

    assert_equals "$exit_status" 1
    assert_contains "$output" 'Result: INCONCLUSIVE'
    assert_file_contains "$run_dir/stages.tsv" $'benchmark-single-run-1\t125\tERROR'
    assert_file_contains "$run_dir/benchmark-single-run-1.log" \
        'benchmark frequency collector failed to start'
    [[ ! -e $run_dir/benchmark-frequency-summary.tsv ]] ||
        fail 'missing frequency evidence produced a frequency summary'
}

write_benchmark_fixture() {
    local directory=$1
    local version=$2
    local single_add=$3
    local multi_add=$4
    local duration=${5:-60s}
    local single_bzy=${6:-4500}
    local multi_bzy=${7:-4200}

    mkdir -p "$directory"
    {
        printf 'format_version\t2\n'
        printf 'cpu_list\t2\n'
        printf 'single_cpu\t2\n'
        printf 'online_cpu_list\t2\n'
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
    {
        printf 'scope\tpackage\tcore\tcpu\tmedian_bzy_mhz\tp05_bzy_mhz\tp95_bzy_mhz\tmedian_avg_mhz\tmedian_busy_percent\tsample_count\n'
        printf 'single\t0\t1\t2\t%s\t%s\t%s\t%s\t99.000\t9\n' \
            "$single_bzy" "$((single_bzy - 50))" "$((single_bzy + 50))" \
            "$((single_bzy - 100))"
        printf 'multi\t0\t1\t2\t%s\t%s\t%s\t%s\t98.000\t9\n' \
            "$multi_bzy" "$((multi_bzy - 50))" "$((multi_bzy + 50))" \
            "$((multi_bzy - 100))"
    } > "$directory/benchmark-frequency-summary.tsv"
    {
        printf 'cpu\tpolicy\tscaling_driver\tscaling_governor\tscaling_min_khz\tscaling_max_khz\tcpuinfo_min_khz\tcpuinfo_max_khz\tboost\tno_turbo\n'
        printf '2\tpolicy2\tmock-driver\tperformance\t1000000\t5000000\t800000\t5200000\tunavailable\t0\n'
    } > "$directory/benchmark-cpu-config.tsv"
}

test_compare_reports_metric_deltas() {
    local output

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800 60s 4500 4200
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760 60s 4590 4116

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate")

    assert_contains "$output" $'scope\tmetric\tbaseline\tcandidate\tdelta_percent'
    assert_contains "$output" $'single\tfloat128add Mfp-ops/sec\t100.000\t105.000\t+5.000'
    assert_contains "$output" $'multi\tfloat128add Mfp-ops/sec\t800.000\t760.000\t-5.000'
    assert_contains "$output" 'Achieved CPU frequency:'
    assert_contains "$output" $'single\t0\t1\t2\t4450.000\t4540.000\t4500.000\t4590.000\t+2.000\t99.000\t99.000'
    assert_contains "$output" $'multi\t0\t1\t2\t4150.000\t4066.000\t4200.000\t4116.000\t-2.000\t98.000\t98.000'
    assert_contains "$output" 'CPU frequency configuration:'
    assert_contains "$output" $'2\tscaling_governor\tperformance\tperformance'
}

test_compare_rejects_missing_frequency_evidence() {
    local output
    local exit_status

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760
    rm "$TEST_TMP/candidate/benchmark-frequency-summary.tsv"

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'both runs must contain benchmark-frequency-summary.tsv'
}

test_compare_rejects_frequency_topology_mismatch() {
    local output
    local exit_status

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760
    sed -i $'s/\t2\t4500/\t3\t4500/' "$TEST_TMP/candidate/benchmark-frequency-summary.tsv"

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'frequency summaries are malformed or CPU sets differ'
}

test_compare_rejects_too_few_frequency_samples_for_repetitions() {
    local output
    local exit_status

    write_benchmark_fixture "$TEST_TMP/baseline" 'stress-ng mock 1.0' 100 800
    write_benchmark_fixture "$TEST_TMP/candidate" 'stress-ng mock 1.0' 105 760
    sed -i $'s/\t9$/\t8/' "$TEST_TMP/candidate/benchmark-frequency-summary.tsv"

    output=$("$HARNESS" compare "$TEST_TMP/baseline" "$TEST_TMP/candidate" 2>&1)
    exit_status=$?

    assert_equals "$exit_status" 2
    assert_contains "$output" 'frequency summaries are malformed or CPU sets differ'
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

test_worker_sigkill_does_not_orphan_stressor() {
    local harness_pid
    local stress_pid

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
    kill -KILL "$harness_pid"
    wait "$harness_pid" 2>/dev/null || true

    if ! wait_for_exit "$stress_pid"; then
        kill -KILL "$stress_pid" 2>/dev/null || true
        fail 'stress process survived worker SIGKILL'
    fi
    [[ -f $TEST_TMP/stress.term ]] || fail 'broker did not terminate stressor after worker SIGKILL'
}

test_run_uses_one_persistent_privileged_broker() {
    local output
    local sudo_log
    local command_count
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        SUDO_COMMAND_LOG="$TEST_TMP/sudo-commands.log" \
        SUDO_REJECT_AFTER_BROKER=1 \
        SUDO_BROKER_MARKER="$TEST_TMP/broker-started" \
        "$HARNESS" memory-cache --yes --no-tui --cache-duration 1s \
        --cpu-list 0 --output "$TEST_TMP/runs")
    run_dirs=("$TEST_TMP/runs"/*)
    run_dir=${run_dirs[0]}
    sudo_log=$(< "$TEST_TMP/sudo-commands.log")
    command_count=$(grep -c '^validate=0 ' "$TEST_TMP/sudo-commands.log")

    assert_contains "$output" 'Result: PASS'
    assert_equals "$command_count" 1
    assert_contains "$sudo_log" 'args=-n --'
    assert_contains "$sudo_log" '__broker'
    assert_not_contains "$sudo_log" 'args=-- setsid'
    assert_file_contains "$run_dir/state" 'status=COMPLETE'
}

test_broker_transfer_failures_cannot_leave_accepted_evidence() {
    local output
    local run_dirs
    local run_dir

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" BASE64_ENCODE_FAIL=1 \
        "$HARNESS" cpu-sustained --yes --no-tui --cpu-duration 1s \
        --cpu-list 0 --output "$TEST_TMP/encode-runs" 2>&1)
    run_dirs=("$TEST_TMP/encode-runs"/*)
    run_dir=${run_dirs[0]}
    assert_not_contains "$output" 'Result: PASS'
    [[ ! -s $run_dir/cpu-sustained.log ]] || fail 'partial encoded stage log survived'

    create_mock_tools
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" BASE64_DECODE_FAIL=1 \
        "$HARNESS" cpu-sustained --yes --no-tui --cpu-duration 1s \
        --cpu-list 0 --output "$TEST_TMP/decode-runs" 2>&1)
    run_dirs=("$TEST_TMP/decode-runs"/*)
    run_dir=${run_dirs[0]}
    assert_not_contains "$output" 'Result: PASS'
    [[ ! -s $run_dir/cpu-sustained.log ]] || fail 'partial decoded stage log survived'
}

test_authentication_uses_configured_askpass_with_terminal_fallback() {
    local output
    local sudo_log

    create_mock_tools
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/askpass"
    chmod +x "$TEST_TMP/askpass"
    PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        SUDO_ASKPASS="$TEST_TMP/askpass" \
        SUDO_COMMAND_LOG="$TEST_TMP/sudo-commands.log" \
        bash -c 'source "$1"; authenticate_sudo' stress-uv-test "$HARNESS" >/dev/null
    sudo_log=$(< "$TEST_TMP/sudo-commands.log")
    assert_contains "$sudo_log" 'askpass=1 args=-A -v'
    assert_not_contains "$sudo_log" 'askpass=0 args=-v'

    : > "$TEST_TMP/sudo-commands.log"
    output=$(PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        SUDO_ASKPASS="$TEST_TMP/askpass" \
        SUDO_ASKPASS_FAIL=1 \
        SUDO_COMMAND_LOG="$TEST_TMP/sudo-commands.log" \
        bash -c 'source "$1"; authenticate_sudo' stress-uv-test "$HARNESS")
    sudo_log=$(< "$TEST_TMP/sudo-commands.log")
    assert_contains "$output" 'falling back to the terminal'
    assert_contains "$sudo_log" 'askpass=1 args=-A -v'
    assert_contains "$sudo_log" 'askpass=0 args=-v'
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

    ' stress-uv-test "$HARNESS" "$TEST_TMP/proc")

    assert_contains "$output" 'matching=alive'
    assert_contains "$output" 'zombie=dead'
    assert_contains "$output" 'reused=dead'
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
        "$HARNESS" benchmark --yes --benchmark-duration 5s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 2 \
        --output "$TEST_TMP/runs"

    output=$(TERM=xterm-256color TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" \
        script -qec "${command% }" /dev/null 2>&1)
    TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" tmux kill-server 2>/dev/null || true

    assert_not_contains "$output" 'tmux setup failed'
    assert_contains "$output" 'Result: PASS'
}

test_tmux_authenticates_worker_tty_before_privileged_commands() {
    local command
    local output
    local sudo_log

    create_mock_tools
    mkdir -m 700 "$TEST_TMP/tmux" "$TEST_TMP/sudo-timestamps"
    cat > "$TEST_TMP/bin/s-tui" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then printf 's-tui mock 1.0\n'; exit 0; fi
trap 'exit 0' INT TERM HUP
while :; do sleep 1; done
EOF
    chmod +x "$TEST_TMP/bin/s-tui"
    printf -v command '%q ' env \
        "PATH=$TEST_TMP/bin:/usr/bin:/bin" \
        "TMUX=" \
        "TMUX_TMPDIR=$TEST_TMP/tmux" \
        "TERM=xterm-256color" \
        SUDO_TTY_TICKETS=1 \
        "SUDO_TIMESTAMP_DIR=$TEST_TMP/sudo-timestamps" \
        "SUDO_LOG=$TEST_TMP/sudo.log" \
        "$HARNESS" benchmark --yes --benchmark-duration 5s \
        --benchmark-warmup 1s --benchmark-runs 1 --cpu-list 2 \
        --output "$TEST_TMP/runs"

    output=$(TERM=xterm-256color TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" \
        script -qec "${command% }" /dev/null 2>&1)
    TMUX= TMUX_TMPDIR="$TEST_TMP/tmux" tmux kill-server 2>/dev/null || true
    sudo_log=$(< "$TEST_TMP/sudo.log")

    assert_contains "$output" 'Result: PASS'
    assert_not_contains "$output" 'a terminal is required'
    assert_not_contains "$output" 'a password is required'
    assert_contains "$sudo_log" 'validate tty=pts/'
    assert_contains "$sudo_log" 'noninteractive=1 auth=hit'
    assert_not_contains "$sudo_log" 'auth=miss'
    assert_not_contains "$sudo_log" 'tty=none'
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
run_test 'benchmark rejects durations too short for frequency evidence' test_benchmark_rejects_duration_too_short_for_frequency_evidence
run_test 'CPU plan is sequential and cycles each CPU' test_cpu_dry_run_is_sequential_and_cycles_each_cpu
run_test 'all plan runs CPU before memory' test_all_dry_run_orders_cpu_before_memory
run_test 'memory plan uses official tools sequentially' test_memory_dry_run_uses_stressapptest_and_memtester_sequentially
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
run_test 'headless official memory stages record commands' test_headless_official_memory_stages_record_commands
run_test 'official memory errors are failures' test_official_memory_errors_are_failures
run_test 'headless benchmark writes metrics and summary' test_headless_benchmark_writes_metrics_and_summary
run_test 'headless benchmark uses recorded CPU sets' test_headless_benchmark_uses_recorded_cpu_sets
run_test 'headless benchmark rejects partial CPU frequency evidence' test_headless_benchmark_rejects_partial_cpu_frequency_evidence
run_test 'headless benchmark rejects inconsistent metric sets' test_headless_benchmark_rejects_inconsistent_metric_sets
run_test 'headless benchmark rejects missing metrics' test_headless_benchmark_rejects_missing_metrics
run_test 'headless benchmark rejects duplicate metrics' test_headless_benchmark_rejects_duplicate_metrics
run_test 'headless benchmark requires frequency evidence' test_headless_benchmark_requires_frequency_evidence
run_test 'compare reports benchmark metric deltas' test_compare_reports_metric_deltas
run_test 'compare rejects missing frequency evidence' test_compare_rejects_missing_frequency_evidence
run_test 'compare rejects frequency topology mismatch' test_compare_rejects_frequency_topology_mismatch
run_test 'compare rejects too few frequency samples for repetitions' test_compare_rejects_too_few_frequency_samples_for_repetitions
run_test 'compare rejects incompatible benchmark context' test_compare_rejects_incompatible_context
run_test 'compare rejects different benchmark protocols' test_compare_rejects_different_benchmark_protocols
run_test 'compare rejects duplicate context keys' test_compare_rejects_duplicate_context_keys
run_test 'compare rejects invalid summary contract' test_compare_rejects_invalid_summary_contract
run_test 'compare rejects disjoint scope metrics' test_compare_rejects_disjoint_scope_metrics
run_test 'headless stage propagates stressor failure' test_headless_stage_propagates_stressor_failure
run_test 'signals stop stressor and mark run aborted' test_signal_stops_stressor_and_marks_run_aborted
run_test 'worker SIGKILL does not orphan stressor' test_worker_sigkill_does_not_orphan_stressor
run_test 'idle broker exits when worker dies' test_idle_broker_exits_when_worker_dies
run_test 'malformed shutdown acknowledgement forces broker stop' test_malformed_shutdown_acknowledgement_forces_broker_stop
run_test 'broker teardown does not signal reused PID' test_broker_teardown_does_not_signal_reused_pid
run_test 'run uses one persistent privileged broker' test_run_uses_one_persistent_privileged_broker
run_test 'broker transfer failures cannot leave accepted evidence' test_broker_transfer_failures_cannot_leave_accepted_evidence
run_test 'authentication uses askpass with terminal fallback' test_authentication_uses_configured_askpass_with_terminal_fallback
run_test 'process identity rejects zombies and PID reuse' test_process_identity_rejects_zombies_and_pid_reuse
run_test 'launcher detach marker lets worker continue' test_launcher_detach_marker_allows_worker_to_continue
run_test 'tmux setup failure rolls back session' test_tmux_setup_failure_rolls_back_session
run_test 'tmux benchmark supports nonzero base indices' test_tmux_benchmark_supports_nonzero_window_and_pane_base_indices
run_test 'tmux authenticates worker tty before privileged commands' test_tmux_authenticates_worker_tty_before_privileged_commands
run_test 'signals to tmux launcher abort session and stressor' test_signal_to_tmux_launcher_aborts_session_and_stressor

printf '1..%d\n' "$TESTS_RUN"
exit "$TESTS_FAILED"
