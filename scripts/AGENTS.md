# AGENTS.md (scripts/)

`anchor-demo.sh [SECONDS]` runs the simulator anchored to a recorded Binance BTCUSDT minute
under `anchor/test/fixtures`, connects `market-maker` to it and prints the anchor's reference
price, the simulator's top of book and the maker's quotes once a second. `LIVE=1` anchors to
Binance mainnet's public streams instead (no keys).

- It assumes the sibling checkouts sit in one dune workspace (`../` from this repository);
  see the header comment in the script for the environment overrides.
- Keep scripts free of hard-coded absolute paths; take them from the environment.
