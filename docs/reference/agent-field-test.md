# Field test prompt — CodeMaster on a real repository

prompt_version: 0.4.0

> **Purpose.** Hand this whole file to an agent (or run it yourself) to test
> CodeMaster end-to-end on YOUR repository in YOUR environment and to return
> one comparable report. The checklist is not a regression suite: its job is
> uniformity of reports, so every line must produce a NUMBER or an explicit
> `N/A`/`BLOCKED` — lines that produced only "ok" were removed on purpose.
> Contract sources: `docs/reference/cli-mcp-contracts.md`,
> `docs/reference/scip-integration.md`, `docs/architecture/configuration.md`.
>
> **Privacy rule (absolute).** The report contains commands, exit codes,
> counters, warning codes, paths and timings — and never source code, secrets,
> credentials or file contents. `config.toml` holds a database password: quote
> nothing from its `[storage]` section.
>
> **Statuses (exactly these).** `PASS` — the number met the stated rule.
> `FAIL` — a number violated it. `N/A (reason)` — the line does not apply to
> this repository/build. `BLOCKED (environment reason)` — could not run here
> (missing toolchain, timeout budget). `SKIPPED (policy)` — deliberately not
> run (e.g. write phases on an adopted live installation). **`PARTIAL` and
> `PASS*` are forbidden** (F6): in one external run 6 of 8 PARTIALs turned
> out to be real bugs; a line must commit to one of the five.
>
> **Evidence bundle (mandatory).** Collect into one directory:
> `manifest.json` (fields from §M, incl. `prompt_version`), `raw/<row>.json`
> (full `--json` output per numbered row), `counters.json` (one
> `cm status --stats --json` per indexed state), `results.json` (machine table
> `{row, status, value}`), `notes.md`. Rule of the bundle: **no number appears
> in the report that is not present in an artifact.** An unverifiable number
> is a FAIL of the report, not of the product.
>
> **Provenance (mandatory).** §M records the full `cm --version` line
> (version + commit + target, ADR-0033), the skills version and the install
> channel; every finding in the report is marked "reproducible on build X".
> A FAIL against a stale build is re-run against the current one before it is
> filed — half the failures of past external reports were fixes already in
> the tree, discovered only by git archaeology.

## Levels

- **core** — rows marked ◆ (≈15 rows, ≈25 minutes): enough for a comparable
  report on any repository.
- **expanded** — everything else: a half-day full audit; run when the core
  passed or when the core itself failed somewhere interesting.

## Adopt or install (§M, no statuses)

Branch first; never overwrite a live installation's work:

- **adopt**: a working `~/.codemaster` (or `CODEMASTER_HOME`) you were given →
  point `CODEMASTER_HOME` at a fresh `$(mktemp -d)` home with your own
  `[storage]` database and *copy nothing* from the live home except the repo
  itself; the live daemon, its config and its index stay untouched; every
  write phase runs against your scratch home. A pre-existing index on the
  target repository is a recorded fact (`adopted: pre-existing index`), not a
  FAIL.
- **install**: `install.sh` (record the verbatim line) or
  `cargo build --release`; binaries from this build only.
- The cold index runs **exactly once** per project in either branch.

## M. Manifest (fields, not checks)

| # | Field | Source |
|---|---|---|
| M.1 | `cm --version` and `cm-daemon --version` (full lines, both binaries) | verbatim |
| M.2 | skills version + install channel (`installer` / `from-source` / `adopted`) | `install.sh` log or `cm --version` sibling; skills manifest under `$CODEMASTER_HOME/skills/` |
| M.3 | OS/CPU/libc: `uname -srm; ldd --version \| head -1; head -2 /etc/os-release` | verbatim |
| M.4 | toolchains the repo needs (`cargo`/`go`/`node`/`python3 --version`) | presence/absence |
| M.5 | repo size: `du -sh`; file count (`find … -type f \| wc -l`) | both numbers |
| M.6 | branch taken: `adopt` or `install` (+ install line if any) | one word + verbatim |

## F0. Environment

| # | Command | Check |
|---|---|---|
| ◆ 0.6 | `cm config explain` | exit 0; `indexing.exclude_dirs` row present (T189); merged with the old 4.1 row: `cm index --explain-config` also exits 0 and prints the same effective config without the daemon; NO coordinates quoted |
| ◆ 0.7 | `cm doctor --json` | exit code and every non-`ok` check (`id`, `status`, message ≤ 200 chars): any `fail` → exit 2; `warn` alone → 0 |

## F1. Basic lifecycle

| # | Command | Check |
|---|---|---|
| ◆ 1.3 | `cm index --json` twice (cold, then warm); time every run | `state: completed`; capture `counters`, all `warnings[].code`, and `data.profile`. Record cold wall time + peak RSS (`/usr/bin/time -v` with the ABSOLUTE `cm` path, or sample `ps -o rss=`) — the old timing row 5.5 lives here: the `profile` breakdown (`scan_ms…resolve_ms`, `resolve_skipped`) belongs in the bundle; warm wall time ≤ 20 % of cold on repos > 1 000 files, else `FAIL` with the two numbers (T194/T211 budget) |
| ◆ 1.4 | counters invariant | cold: `parsed + skipped + unmanaged == discovered`; warm: `+ unchanged == discovered` — the number is the whole check |
| ◆ 1.5 | re-run `cm index --json` | `parsed: 0`, `status.index_epoch` unchanged; `profile.resolve_skipped: true` on a steady worktree (T211) |
| 1.6 | edit one source file (comment line), `cm index --json` | `parsed` ∈ {1,2}, rest `unchanged`, new epoch; then revert. `cm sync --json` is the FULL re-check — never assert `parsed: 1` for it |
| 1.7 | `cm status --json` | `freshness` plausible after sync |

## F2. Core queries (all `--json`, pick real names from YOUR code)

| # | Command | Check |
|---|---|---|
| ◆ 2.1 | `cm search <exact_identifier> --json` | the declaration is found, exact channel ranks first |
| 2.2 | `cm symbol <qualified-name> --json` | span, path, kind match the source |
| ◆ 2.3 | `cm context <symbol> --json` | `budget_used_bytes ≤ budget_bytes`; **`truncated: true` requires non-empty `truncated_by`** (`walk`/`budget`) — a flag without a named cause is a FAIL (T207); when not truncated, `truncated_by` is `[]` |
| ◆ 2.4 | `cm graph callers`/`callees` on one real call | the edge is there, direction right. ALSO record the resolution coverage: from `counters.json` → `sum(edges[resolution=exact].count) / sum(edges.count)` as a percentage; exact-ratio 0 with a typed language is a FAIL number, not an impression |
| ◆ 2.5 | `cm graph implementations <trait-or-interface> --json` on a typed repo | **positive check:** ≥1 implementer present, OR `data.empty_reason` names one of the three kinds, OR the `--stats` counters show `edges implements/<language>` = 0 rows → then `N/A (relation not modeled for this language)`; empty facts with no `empty_reason` and no counter support = FAIL |
| 2.6 | `cm graph impact <symbol> --json` | transitive callers ⊇ direct callers |
| 2.7 | `cm unresolved --json` | every row carries a reason code or a pending hint; spot-check 3 in source |
| 2.8 | `cm quality hotspots complexity.cognitive --json` | descending order, `na_count` present |
| 2.9 | `cm quality modules --json` | rows carry catalog `algorithm` ids |
| ◆ 2.10 | `cm dataflow <symbol> --direction forward --json` (+ backward) | **positive check:** first record `counters.json → dataflow.facts` and `dataflow.bodies`; with facts > 0 but a seed whose `seed_hops` = 0, pick another seed once, then `N/A (seed outside the flow graph)` — the counters (T209: `fact_count` is project-wide, `seed_hops` is the seed's) must be in the bundle BEFORE any path claim; a path with spans/limitations is PASS; no path is never proof of absence |
| ◆ 2.11 | `cm tests <symbol> --json` | **positive check (T206):** choose a symbol that HAS a test in the repo (`grep` for its name inside `*_test.*`); the row is PASS only if `data.tests` is non-empty for it; empty → record `counters.json → tests.total` vs `tests.links`: `total > 0, links == 0` is a FAIL (the silence made visible); `links > 0` but not this symbol → `N/A (naming convention does not link this case)` |
| 2.12 | `cm deps --json`, `cm architecture --json` | manifest deps match reality; `rules: none` when no `layers.toml` |

## F2L. Language expectations (run rows matching YOUR repository)

| # | Repository family | Check |
|---|---|---|
| L.1 | Rust workspace | member crates indexed (more than the root crate) — number of member crates vs `--stats edges[language=rust]` |
| L.2 | Go | `go.mod` module path is the package; `vendor/` absent (F3); **L.7** — pick a method with a receiver: `cm symbol <Type.Method> --json` resolves and `cm graph callers <Method> --json` answers with edges or an `empty_reason` |
| L.3 | JS/TS + Vue | `<script setup>` declarations are symbols of the `.vue` host |
| L.4 | Python | functions/classes resolve |
| L.5 | any listed family | nested artifact directories: **L.8** — `find . -path 'a/b/node_modules' -o -path '*/node_modules/*/node_modules'` (nested copies): nothing under ANY `node_modules` at ANY depth is indexed (search for an identifier that exists only there) |
| L.6 | not listed | `N/A (language not covered)` |

## F3. Third-party exclusion (T189) — mandatory

| # | Command | Check |
|---|---|---|
| ◆ 3.1 | list which of `node_modules`, `vendor`, `target`, `dist`, … exist | a set, not prose |
| 3.2 | for each: `cm search <identifier only inside it> --json` | zero hits; also zero after `indexing.respect_gitignore = false` + `cm index --full-check --json` |
| 3.2b | time guard before 3.3: estimate `find` count with gitignore off | if estimate > 20 000 files OR the probe `cm index --full-check` exceeds 10 min → status `BLOCKED (time budget)` for 3.2/3.3 with the estimate as the number; do NOT grind the session |
| 3.3 | restore config; `cm index --full-check --json` | counts return to the 3.1-state numbers |

## F4. SCIP — keyed on the INDEXER, never on the language

`cm semantic generate` is Rust-only (the managed runner); `cm semantic import`
consumes the SCIP *format* for any language with a verified indexer
(`scip-integration.md` §2: `rust-analyzer`, `scip-go`). The N/A branch binds
to the indexer binary, so `N/A (no verified indexer for this language)` is
wrong for Go when `scip-go` is on PATH — and a `join_matched = 0` on a
foreign-indexer artifact is `BLOCKED (artifact mismatch)`, never a product
FAIL.

| # | Command | Check |
|---|---|---|
| 4.5 | `cm semantic providers --json` | the indexer rows for YOUR language; absent = `available: false` + reason, exit 0 |
| 4.6 | Rust only, `[semantic_indexing.scip] enabled`: `cm semantic generate --json` | run summary; failure → `scip_indexer_*` code and no zombie indexer (`pgrep -P <daemon pid>`) |
| ◆ 4.7 | import a CI artifact: `cm semantic import <index.scip> --json`; then `cm index --json` | run published; re-import of the same bytes → same run id; after the index, `cm graph implementations <iface> --json` on a Go repo answers from the SCIP `Implements` edges (provider `scip` in `cm explain-edge`) — the T217 machine path |
| 4.8 | `cm semantic status --json`, `cm semantic health --json` | `join_matched > 0`; `relationships`/`relationships_dropped` counters visible on the run; `join_reasons` explains the rest |
| 4.9 | `cm explain-edge <fact-uuid> --json` on one scip edge | provider + run identity + external ids; the message ≤ 400 chars and contains no raw SQL |
| 4.10 | `cm index --semantic native --json` | zero `scip_*` warnings this run |
| 4.11 | edit an indexed file → `cm index --json` → re-import | `scip_documents_stale` appears, then clears (T185 cycle) |

## F4P. MCP / CLI parity

| # | Command | Check |
|---|---|---|
| ◆ P.1 | `tools/list` over stdio (initialize → `{"name":"field-test","version":"0"}`) | exactly the 17 read tools (cli-mcp-contracts); stdout carries protocol frames only |
| P.2 | `get_index_status` via MCP vs `cm status --json` | same freshness/counters/schema_version |
| P.3 | `search_code` + `graph_query` vs CLI | same top hit / same edge set; any payload difference = FAIL with both fields quoted |

## F5. Degradation and stress — THROWAWAY checkout only

`CODEMASTER_HOME=$(mktemp -d)` + dedicated database; drop both when done
(`REMOVE NAMESPACE`/`DATABASE`, never the working one).

| # | Action | Check |
|---|---|---|
| ◆ 5.3 | `head -c 2000000 /dev/urandom > scratch/big.rs`; `cm index --json` | run completes; then `cm files --state skipped --json` shows the row with `reason_code: "too_large"` and its `limit_bytes` — no SQL, no `PARTIAL` escape (T208); `cm status --stats --json` `files[]` counts it under `skipped:too_large` |
| ◆ 5.4 | two concurrent `cm index --json` | both terminate; failure message (if any) ≤ 400 chars, contains no raw SQL statement (T199); third run idempotent |
| 5.1 | `kill -9` daemon mid-index | next start reports the run `interrupted`, rebuild reaches the same counters |
| 5.2 | `chmod 000` one dir in the scratch copy | `scan_read_error` warnings; run completes; restore |
| 5.6 | delete a registered file; `cm sync --json` | removals > 0; queries about the symbol not-found; stale edges gone |

## FU. Usage (T200; local-only)

| # | Command | Check |
|---|---|---|
| U.1 | `cm usage summary --json` after the run's commands | `total_events` ≥ the number of daemon calls this test made; every event `surface ∈ {cli, mcp}`; the report quotes counters only — events contain no paths by construction, verify `grep -c "$PWD" ` over `cm usage top --by project --json` output stays 0 |
| U.2 | `cm usage top --json` | method rows include `daemon.health`/`index.run` with totals |

## F6. Report format

```markdown
# CodeMaster field test — <repo>, <date> — build <M.1> · prompt 0.4.0
## Results (core first)
| row | status | value |
|-----|--------|-------|
| 1.3 | PASS   | cold 41.2s / warm 0.31s (0.75 %), RSS 210MB, warnings [git_disabled] |
| 2.11| FAIL   | tests.total=2956 links=0 |
| 3.2b| BLOCKED(time budget) | estimate 31 402 files |
## Anomalies
every FAIL: exact command, exit code, output tail ≤ 20 lines, no sources,
"reproducible on build <M.1>"
## Verdict
what worked, what blocked, what surprised — each claim cites a row id
```

Rules: statuses are exactly the five from the header — **`PARTIAL` and
`PASS*` are banned**; report paths, never file contents; truncate outputs;
every anomaly names the build; a line that could not run carries
`N/A`/`BLOCKED`/`SKIPPED` with its reason; silence in the bundle
(`results.json` missing a row) fails the report.
