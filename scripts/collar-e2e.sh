#!/usr/bin/env bash
# End-to-end run with the price collar and halt rule on: starts binance-sim (seed 42,
# noise traders) with -collar-bps 50 and -halt-levels 7:15m,13:15m,20:reopen, runs
# market-maker against it for SECONDS, then sends one buy limit 2% through the best ask
# and checks that it is refused with Binance's PERCENT_PRICE error (-4016), prints
# GET /sim/guard and POST /sim/reopen, and the maker's report.
#
#   scripts/collar-e2e.sh [SECONDS] [market-maker flags...]
#
# Assumed layout, as for market-maker's scripts/e2e.sh: binance-sim and market-maker are
# checked out next to their siblings inside one dune workspace (<root>/dune-workspace).
# Environment overrides: WORKSPACE (<root>), OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR
# (<root>/_build-binance-sim), PORT (a free port), SEED (42), COLLAR_FLAGS (the guard
# flags above), LOG_DIR (a temporary directory).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$here/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-binance-sim}"
run_for=30
if [[ $# -ge 1 && "$1" =~ ^[0-9]+$ ]]; then
  run_for="$1"
  shift
fi
seed="${SEED:-42}"
read -r -a collar_flags <<<"${COLLAR_FLAGS:--collar-bps 50 -halt-levels 7:15m,13:15m,20:reopen}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/collar-e2e.XXXXXX")}"
mkdir -p "$log_dir"

if [[ ! -d "$root/market-maker" ]]; then
  echo "collar-e2e: $root/market-maker is missing; clone it next to binance-sim" >&2
  exit 1
fi

echo "collar-e2e: building binance-sim and market-maker (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  "$(basename "$here")/bin/main.exe" market-maker/bin/main.exe)
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/$(basename "$here")/bin/main.exe"
mm_exe="$build/market-maker/bin/main.exe"

port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"

sim_pid=""
mm_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  for pid in "$mm_pid" "$sim_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "collar-e2e: starting binance-sim on port $port: ${collar_flags[*]}" >&2
"$sim_exe" -port "$port" -seed "$seed" "${collar_flags[@]}" >"$log_dir/sim.log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 100); do
  curl -sf "$base_url/fapi/v1/ping" >/dev/null 2>&1 && break
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "collar-e2e: binance-sim exited early:" >&2
    cat "$log_dir/sim.log" >&2
    exit 1
  fi
  sleep 0.2
done
# Let the noise traders build a two-sided book.
sleep 2

echo "collar-e2e: running market-maker for ${run_for}s, log $log_dir/mm.log" >&2
status=0
"$mm_exe" -venue binance -network local -base-url "$base_url" -run-for "$run_for" "$@" \
  >"$log_dir/report.txt" 2>"$log_dir/mm.log" || status=$?
cat "$log_dir/report.txt"
if [[ $status -ne 0 ]]; then
  echo "collar-e2e: market-maker exited with $status; last log lines:" >&2
  tail -20 "$log_dir/mm.log" >&2
fi

ask="$(curl -sf "$base_url/fapi/v1/ticker/bookTicker?symbol=BTCUSDT" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["askPrice"])')"
price="$(python3 -c "print(f'{round(float(\"$ask\") * 1.02, 1):.1f}')")"
echo "--- buy 0.01 BTCUSDT at $price (best ask $ask) ---"
reply="$(curl -s -X POST -H 'X-MBX-APIKEY: collar-e2e' \
  "$base_url/fapi/v1/order?symbol=BTCUSDT&side=BUY&type=LIMIT&timeInForce=GTC&price=$price&quantity=0.01&timestamp=1")"
echo "$reply"
echo "--- GET /sim/guard ---"
curl -s "$base_url/sim/guard" | python3 -c '
import json, sys
g = json.load(sys.stdin)
g["recent"] = g["recent"][-3:]
print(json.dumps(g, indent=1))'
echo "--- POST /sim/reopen ---"
curl -s -X POST "$base_url/sim/reopen" | python3 -c '
import json, sys
g = json.load(sys.stdin)
print(json.dumps({"halted": g["halted"], "stats": g["stats"]}))'

code="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("code"))' "$reply")"
if [[ "$code" != "-4016" ]]; then
  echo "collar-e2e: FAILED: expected code -4016, got $code" >&2
  status=1
else
  echo "collar-e2e: collar rejection mapped to -4016" >&2
fi
exit "$status"
