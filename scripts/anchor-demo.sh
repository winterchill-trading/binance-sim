#!/usr/bin/env bash
# Runs binance-sim anchored to a recorded Binance BTCUSDT minute (the raw minute files
# under anchor/test/fixtures) with no noise traders, connects market-maker to it, and
# prints once a second: the anchor's reference price and state, the simulator's best bid
# and ask (the reference's top levels, resting from the anchor account), and the market
# maker's best quotes. The maker's quotes follow the reference as it moves.
#
#   scripts/anchor-demo.sh [SECONDS]
#
# SECONDS (default 30) is how long market-maker runs. The recording covers about 6.5
# seconds of trading; SPEED (default 0.25) stretches it to about 26 seconds. LIVE=1
# anchors to Binance mainnet instead (read-only public streams, no keys needed).
#
# Assumed layout, as for market-maker's scripts/e2e.sh: binance-sim and market-maker are
# checked out next to their siblings inside one dune workspace (<root>/dune-workspace).
# Environment overrides: WORKSPACE (<root>), OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR
# (<root>/_build-binance-sim), PORT (a free port), SPEED, LIVE, LOG_DIR.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$here/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-binance-sim}"
run_for="${1:-30}"
speed="${SPEED:-0.25}"
log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/anchor-demo.XXXXXX")}"
mkdir -p "$log_dir"

if [[ ! -d "$root/market-maker" ]]; then
  echo "anchor-demo: $root/market-maker is missing; clone it next to binance-sim" >&2
  exit 1
fi

echo "anchor-demo: building binance-sim and market-maker (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  "$(basename "$here")/bin/main.exe" market-maker/bin/main.exe)
build="$DUNE_BUILD_DIR/default"
sim_exe="$build/$(basename "$here")/bin/main.exe"
mm_exe="$build/market-maker/bin/main.exe"

port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"

if [[ -n "${LIVE:-}" ]]; then
  source_flags=()
else
  source_flags=(-anchor-raw "$here/anchor/test/fixtures"
    -anchor-from 2026-10-12T15:05:00Z -anchor-to 2026-10-12T15:06:00Z
    -anchor-speed "$speed")
fi

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

echo "anchor-demo: starting binance-sim on port $port, log $log_dir/sim.log" >&2
"$sim_exe" -port "$port" -noise-traders 0 -anchor binance:BTCUSDT=BTCUSDT \
  "${source_flags[@]}" >"$log_dir/sim.log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 100); do
  curl -sf "$base_url/fapi/v1/ping" >/dev/null 2>&1 && break
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "anchor-demo: binance-sim exited early:" >&2
    cat "$log_dir/sim.log" >&2
    exit 1
  fi
  sleep 0.1
done

key=anchor-demo-mm
# A replay slower than real time stamps the simulator's book with recorded time, which
# falls behind the wall clock; let the maker accept book times that far back.
printf '((max_data_age_ms 600000))\n' >"$log_dir/params.sexp"
echo "anchor-demo: running market-maker for ${run_for}s, log $log_dir/mm.log" >&2
BINANCE_API_KEY="$key" BINANCE_API_SECRET=unused \
  "$mm_exe" -venue binance -network local -base-url "$base_url" -run-for "$run_for" \
  -params "$log_dir/params.sexp" >"$log_dir/report.txt" 2>"$log_dir/mm.log" &
mm_pid=$!

printf '%-8s %-6s %-11s %-23s %-23s %s\n' \
  time state reference "sim bid / ask" "maker bid / ask" "replay fills"
start=$(date +%s)
while kill -0 "$mm_pid" 2>/dev/null; do
  anchor="$(curl -sf "$base_url/sim/anchor" || echo '[{}]')"
  book="$(curl -sf "$base_url/fapi/v1/ticker/bookTicker?symbol=BTCUSDT" || echo '{}')"
  orders="$(curl -sf -H "X-MBX-APIKEY: $key" \
    "$base_url/fapi/v1/openOrders?symbol=BTCUSDT&timestamp=1" || echo '[]')"
  printf '%-8s %-6s %-11s %-23s %-23s %s\n' \
    "+$(($(date +%s) - start))s" \
    "$(jq -r '.[0].state // "-"' <<<"$anchor")" \
    "$(jq -r '.[0].reference_price // "-"' <<<"$anchor")" \
    "$(jq -r '"\(.bidPrice // "-") / \(.askPrice // "-")"' <<<"$book")" \
    "$(jq -r '[.[] | select(.side == "BUY") | .price | tonumber] as $b
              | [.[] | select(.side == "SELL") | .price | tonumber] as $a
              | "\($b | max // "-") / \($a | min // "-")"' <<<"$orders")" \
    "$(jq -r '.[0].replay_fills // "-"' <<<"$anchor")"
  sleep 1
done

status=0
wait "$mm_pid" || status=$?
mm_pid=""
echo "--- anchor status ---"
curl -sf "$base_url/sim/anchor" | jq .
echo "--- market-maker report ---"
cat "$log_dir/report.txt"
if [[ $status -ne 0 ]]; then
  echo "anchor-demo: market-maker exited with $status; last log lines:" >&2
  tail -20 "$log_dir/mm.log" >&2
fi
exit "$status"
