#!/bin/zsh
# Development only. Measures SilkNest with a 1000-item history (text, code, links, ~100 screenshot-sized
# images) on throwaway automation data: launch time, Nest open time, search latency, memory at idle,
# with the Nest open and with the spider hidden.
#
# It quits a running SilkNest, runs an optimized build with developer automation (-DDEBUG, --automation:
# its history, notes and key live in a temporary folder, never the user's), and reopens SilkNest after.
# The Nest opens on screen a few times during the run. Nothing is read from or written to the clipboard.
#
#   zsh scripts/perf.sh            → prints a JSON report and saves it to .build/perf/report.json
set -euo pipefail
cd "${0:A:h}/.."
OUT=.build/perf; mkdir -p $OUT
swift build -c release -Xswiftc -DDEBUG --build-path $OUT >/dev/null
BIN=$OUT/release/WEBBER
swiftc -O scripts/automation-post.swift -o $OUT/post 2>/dev/null
LOG=$OUT/run.log

# Throwaway automation data only (see AppData.defaultRoot / OverlayController.history in --automation).
TMP="$(getconf DARWIN_USER_TEMP_DIR)"
rm -rf "$TMP/webber-automation-support" "$TMP/webber-automation-history" "$TMP/webber-automation-notes.enc"

RUNNING="$(ps -axo command= | grep -E '/SilkNest\.app/Contents/MacOS/SilkNest$' | head -1 | sed 's#/Contents/MacOS/SilkNest$##' || true)"
pkill -x SilkNest 2>/dev/null || true; sleep 1
cleanup() { pkill -f "$BIN --automation" 2>/dev/null || true; [[ -n "$RUNNING" ]] && open -g "$RUNNING"; }
trap cleanup EXIT

now() { python3 -c 'import time; print(time.time())'; }
send() { $OUT/post "$1"; sleep "${2:-0.4}"; }
# A fresh state line: any command makes the app print its state (an unknown one changes nothing).
state() { $OUT/post ping; sleep 0.3; grep '^WEBBER-STATE ' $LOG | tail -1 | sed 's/^WEBBER-STATE //'; }
start() {
  : > $LOG
  local t0=$(now)
  $BIN --automation > $LOG 2>/dev/null &
  until grep -q 'automation channel ready' $LOG 2>/dev/null; do sleep 0.02; done
  python3 -c "print(round(($(now)-$t0)*1000))"
}

# 1. Seed once, then quit so the next launch loads the full history from disk.
start >/dev/null
send "seed:1000:100" 1
until grep -q 'WEBBER: seeded' $LOG; do sleep 0.5; done
sleep 2; send quit 2; pkill -f "$BIN --automation" 2>/dev/null || true; sleep 1

# 2. Measured run.
LAUNCH=$(start)
# Same display every run (the primary one, where the menu bar is): render surfaces scale with it.
send screen:0 1; send nestOnSpider:on; send patrol:off; send outsideClose:off; sleep 14
# Memory: five samples a second apart (GPU memory is released lazily, single readings jump around).
mem() { local out=(); for i in 1 2 3 4 5; do out+=("$(state | python3 -c 'import json,sys; print(json.load(sys.stdin)["perf"]["footprintMB"])')"); sleep 0.7; done; echo "${(j:,:)out}"; }
IDLE=$(state); IDLE_MEM=$(mem)
# Idle CPU: CPU time used over 10 s of a still spider (percent of one core).
PID=$(pgrep -f "$BIN --automation" | head -1)
cpu_s() { ps -o time= -p $PID | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
C0=$(cpu_s); sleep 10; C1=$(cpu_s)
IDLE_CPU=$(python3 -c "print(round(($C1-$C0)/10*100,2))")
send nest 4
OPEN=$(state); OPEN_MEM=$(mem)
SEARCH=(); COMPUTE=()
for ch in s c r e e n; do
  send "nestType:$ch" 0.35; S=$(state)
  SEARCH+=("$(echo $S | python3 -c 'import json,sys; print(json.load(sys.stdin)["perf"]["searchMs"])')")
  COMPUTE+=("$(echo $S | python3 -c 'import json,sys; print(json.load(sys.stdin)["perf"].get("searchComputeMs",-1))')")
done
TYPED=$(state)
send esc 1.5; send "visible:off" 8
HIDDEN=$(state); HIDDEN_MEM=$(mem)
send quit 1

python3 - "$LAUNCH" "$IDLE" "$OPEN" "$TYPED" "$HIDDEN" "${(j:,:)SEARCH}" "${(j:,:)COMPUTE}" "$IDLE_MEM" "$OPEN_MEM" "$HIDDEN_MEM" "$IDLE_CPU" <<'PY' | tee $OUT/report.json
import json, sys
launch, idle, opened, typed, hidden, search, compute, mi, mo, mh, cpu = sys.argv[1:12]
def mem(s):
    v = sorted(float(x) for x in s.split(","))
    return {"steadyMB": round(v[0], 1), "medianMB": round(v[len(v)//2], 1), "maxMB": round(v[-1], 1)}
p = lambda s: json.loads(s)["perf"]
i, o, t, h = p(idle), p(opened), p(typed), p(hidden)
print(json.dumps({
  "historyItems": i["historyCount"],
  "launchToReadyMs": int(launch),
  "historyLoadMs": round(i["historyLoadMs"], 1),
  "nestOpenMs": round(o["nestOpenMs"], 1),
  "searchMsPerKeystroke": [round(float(x), 2) for x in search.split(",")],
  "searchComputeMsPerKeystroke": [round(float(x), 2) for x in compute.split(",")],
  "resultsFor_screen": t["nestTotal"],
  "idleCpuPercent": float(cpu),
  "memoryIdle": mem(mi),
  "memoryNestOpen": mem(mo),
  "memorySpiderHidden": mem(mh),
  "contentInMemoryMB": round(i["inMemoryContentMB"], 1),
}, indent=2))
PY
