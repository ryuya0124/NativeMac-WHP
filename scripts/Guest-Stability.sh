#!/bin/bash
# Authored FHD rendering plus repeated checked, no-copy GPU memory churn.
# Run in the guest after deploying the SHA-checked probes and task runner.
set -u
duration=${1:-1800}
case "$duration" in ''|*[!0-9]*) exit 64;; esac
if [ "$duration" -lt 60 ] || [ "$duration" -gt 1800 ]; then exit 64; fi
: "${NATIVEMAC_LAB_BASE:?temporary local result channel required}"
lab="$HOME/NativeMacLab/probes"
runner="$HOME/NativeMacLab/task-runner-x64"
for executable in "$runner" "$lab/scene-probe-x64" "$lab/buffer-lifetime-x64"; do
    [ -x "$executable" ] || exit 66
done
report="$lab/stability-progress.log"
scene_log="$lab/stability-scene.log"
buffer_log="$lab/stability-buffer.log"
scene_pid=
awake_pid=
cleanup() {
    if [ -n "$scene_pid" ]; then kill -TERM "$scene_pid" 2>/dev/null || true; fi
    if [ -n "$awake_pid" ]; then kill -TERM "$awake_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
post() {
    curl -fsS --max-time 10 --data-binary @"$report" "${NATIVEMAC_LAB_BASE}result"
}

# A bounded assertion prevents test-time display/system idle. No persistent
# sleep, lock, authentication or security setting is changed.
/usr/bin/caffeinate -dimsu -t "$((duration+45))" &
awake_pid=$!
"$lab/scene-probe-x64" "$duration" > "$scene_log" 2>&1 &
scene_pid=$!
started=$SECONDS
next_check=60
checks=0
failed=0
echo "BANKED_STABILITY_STARTED duration=$duration" > "$report"
post || failed=1
while kill -0 "$scene_pid" 2>/dev/null; do
    sleep 5
    elapsed=$((SECONDS-started))
    if [ "$elapsed" -gt "$((duration+45))" ]; then
        echo "BANKED_STABILITY_TIMEOUT elapsed=$elapsed" > "$report"
        post || true
        failed=1
        break
    fi
    if [ "$elapsed" -ge "$next_check" ]; then
        "$runner" 20 "$lab/buffer-lifetime-x64" --large > "$buffer_log" 2>&1
        buffer_exit=$?
        checks=$((checks+1))
        {
            echo "BANKED_STABILITY_PROGRESS elapsed=$elapsed memoryChecks=$checks bufferExit=$buffer_exit"
            tail -1 "$scene_log"
            tail -2 "$buffer_log"
        } > "$report"
        post || failed=1
        if [ "$buffer_exit" -ne 0 ]; then failed=1; break; fi
        next_check=$((SECONDS-started+60))
    fi
done
if [ "$failed" -ne 0 ]; then
    kill -TERM "$scene_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$scene_pid" 2>/dev/null || true
fi
wait "$scene_pid"
scene_exit=$?
scene_pid=
{
    echo "BANKED_STABILITY_FINAL elapsed=$((SECONDS-started)) sceneExit=$scene_exit memoryChecks=$checks wrapperFailed=$failed"
    tail -5 "$scene_log"
    tail -2 "$buffer_log"
} > "$report"
post || failed=1
[ "$scene_exit" -eq 0 ] && [ "$failed" -eq 0 ]
