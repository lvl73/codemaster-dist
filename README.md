# CodeMaster

**CodeMaster (`cm`)** is a local-first code intelligence engine for AI coding agents and developers. It builds a versioned, evidence-backed model of a repository and exposes the same capabilities through a terminal CLI and MCP.

The product is not intended to replace source files, compilers, tests, debuggers, or web search. It reduces repeated repository discovery and makes structural, semantic, quality, history, and data-flow information queryable.

## Product principles

- Rust implementation; modular monolith first, with explicit ports and adapters.
- One local SurrealDB database for all persistent indexes. No SQLite project index.
- SurrealDB runs as a local Docker service for development and tests; `cm daemon` is the only writer.
- One `cm daemon` process owns the embedded SurrealDB/SurrealKV store. CLI and MCP are clients of the daemon; they must not independently open the same embedded database directory.
- Tree-sitter is the syntax backbone. LSP/compiler frontends enrich semantic resolution where available; unsupported or unresolved facts remain explicitly uncertain.
- Deterministic retrieval and analysis are the default. An internal agentic reasoning mode is optional and must not be required for ordinary search.
- CLI and MCP call the same application services and return equivalent structured results.
- Index facts carry provenance, source locations, content hashes, analyzer versions, and confidence where applicable.
- Quality metrics are measurements with declared algorithms and limitations, not an opaque universal quality score.
- Indexing breadth and depth are configurable independently, including Git history.

## Install (Ubuntu/macOS)

Release binaries are published by the `Release` workflow for
`x86_64/aarch64` Linux and macOS. One command installs `cm`, `cm-mcp`,
`cm-daemon` and can start the local SurrealDB service:

```bash
curl -fsSL https://github.com/lvl73/codemaster/releases/latest/download/install.sh -o install.sh
sudo sh install.sh
```

The installer lets you choose how SurrealDB runs (docker compose, plain
`docker run`, `podman`, or your own instance) and, in an interactive run, asks
for the image, credentials and port; pressing Enter at the password prompt
generates a random one. Flags and environment variables skip the corresponding
question — required for non-interactive runs (`--yes`). `sh install.sh --help`
lists everything:

```bash
# non-interactive example
sh install.sh --yes --db docker --password "$(openssl rand -hex 16)" --port 8001
# build from source instead of downloading release assets
sh install.sh --from-source --db compose
```

Defaults match `docker-compose.yml` in this repository: image
`surrealdb/surrealdb:v4.0.0`, loopback port `8001`,
namespace `codemaster`. Non-default credentials are appended as a `[storage]`
section to `$CODEMASTER_HOME/config.toml`. After installation:

```bash
cm init && cm index          # in a project directory
```

and register `cm-mcp` as an MCP server in your agent config (the installer
prints a ready-to-paste `opencode.json` snippet with the installed path).

The release flow is reproducible locally before publishing; the Makefile
targets and assets are documented in
[`docs/reference/release-flow.md`](docs/reference/release-flow.md).

## Agent skills

CodeMaster ships portable skills (`cm-explore`, `cm-impact`, `cm-debug`,
`cm-quality`, `cm-refactor`, `beads`) in the open
[Agent Skills](https://agentskills.io) format. They arrive as a release asset
and are staged in `$CODEMASTER_HOME/skills/` (default `~/.codemaster/skills/`).
Installing them into an agent is an explicit, separate action:

```bash
cm skill list                                              # what is available
cm skill install --agent opencode --scope project --yes
cm skill status --agent claude --scope global              # ok / modified / outdated
cm skill remove --agent opencode                           # deletes only our files
```

Scope is never guessed: non-interactively `cm skill install` requires both
`--agent` and `--scope` and otherwise refuses, so CI and agents cannot write
into places nobody chose. Verified target layouts, install guarantees, and the
`codex`/`AGENTS.md` exception are documented in
[`docs/architecture/agent-interfaces.md`](docs/architecture/agent-interfaces.md) §4.

## Development

The pipeline is end to end: `cm index` / `cm sync` build the index from the
worktree (Tree-sitter grammars for Rust, Python, Go, PHP, JS/TS, including
Vue/React fragments; LSP enrichment where available), and the same indexed
facts answer queries through `cm search`, `cm symbol`, `cm context`,
`cm unresolved`, `cm graph` (callers, callees, implementations, impact),
`cm quality` (hotspots, metrics, explain), `cm dataflow` (sources, traces to
sinks), `cm git` (history, changes, blame, co-change), and the knowledge
family `cm tests` / `cm deps` / `cm coverage` / `cm architecture`. CLI, MCP
(`cm-mcp`, stdio) and the read-only web admin (`cm-admin`) call the same
application use cases. `cm status` / `cm overview` report index freshness and
capabilities honestly, including partial states.

The workspace is split into `crates/*` (domain, application, config, rpc,
storage, daemon, cli, mcp, indexer, parsers, lsp, git, dataflow, admin);
crate boundaries and forbidden dependency directions are fixed by ADR-0015
and enforced by architecture fitness tests.

Milestone content, decomposition and status live in the beads tracker;
[`docs/implementation/roadmap.md`](docs/implementation/roadmap.md) is only a
pointer to it. Architectural decisions and their consequences are recorded in
[`docs/adr/`](docs/adr/); when implementation changes a decision, update the
relevant ADR and documentation in the same change.

Toolchain: Rust 1.99.1 is pinned in `rust-toolchain.toml`; the workspace MSRV is
1.95 because SurrealDB 4.0 depends on `sysinfo` 0.39. See
[`docs/adr/0017-rust-toolchain-and-surrealdb-pin.md`](docs/adr/0017-rust-toolchain-and-surrealdb-pin.md).

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo build --workspace --bins --locked
cargo test --workspace --locked

# Local smoke test (Unix)
docker compose up -d surrealdb
export CODEMASTER_HOME="$(mktemp -d)"
cargo run -p cm-cli -- daemon start
cargo run -p cm-cli -- daemon status
cargo run -p cm-cli -- init
cargo run -p cm-cli -- status
cargo run -p cm-cli -- daemon stop
```
