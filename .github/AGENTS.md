# AGENTS.md (.github/)

`workflows/ci.yml` builds and tests both packages with the `ox-setup` action. Its `pins:` block
lists the sibling repositories in dependency order, including `binance-client` (used by the
anchor package); keep it in sync with `dune-project`. The `obj-magic` job calls the shared
reusable workflow from the `infra` repository.
