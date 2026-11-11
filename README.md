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

## Install (Linux, and macOS from source)

Requirements for the published binaries: Linux on `x86_64` or `aarch64` with
**glibc >= 2.35** (Ubuntu 22.04, Debian 12; the builds in fact need only 2.34) —
the release baseline of
[ADR-0026](docs/adr/0026-linux-baseline-glibc-2-35.md) — plus Docker, Podman or
your own SurrealDB 4.0.0 for the database. `cm doctor --deep` checks the
installation, the coordinates, the database port and whether these binaries
actually run here.

Release binaries are published for Linux `x86_64` and `aarch64`; the macOS legs
are parked (the repository currently has no macOS runners), so on macOS build
from source with `--from-source`. One command installs `cm`, `cm-mcp`,
`cm-daemon` and can start the local SurrealDB service:

```bash
curl -fsSL https://raw.githubusercontent.com/lvl73/codemaster-dist/master/install.sh -o install.sh
sh install.sh
```

Run it as the user who will use CodeMaster — **no `sudo`**. The installer picks a
writable directory that is already on `PATH` (`~/.local/bin` by default);
`/usr/local/bin` is used only for a root install or after an explicit
confirmation. A `sudo` install is legitimate but shared: the daemon, its socket,
`config.toml` and the staged skills belong to the home of the user who ran it,
so `/root/.codemaster` is invisible to your own `cm`, which then reports the
daemon as unavailable. The installer warns when it is started as root.

What the installer decides on its own:

- **OS, CPU and C library** (`uname` plus `ldd`/musl probes) select the asset
  `cm-<triple>.tar.gz`. A host the release does not cover is refused with the
  concrete alternatives (`--from-source`, `--triple`, `--libc`,
  `--allow-unsupported`) instead of installing a binary whose only output is a
  loader error.
- **glibc baseline**: published builds target glibc >= 2.35 (Ubuntu 22.04,
  Debian 12); an older host is refused before download, and `--min-glibc`
  changes the contract.
- **Checksums**: every downloaded asset (binaries and skills) is verified
  against its published `.sha256`; a missing checksum aborts the install unless
  `--allow-unverified` is given.
- **It runs what it downloaded**: `cm --version` is executed from the temporary
  directory before anything reaches `PATH`, so a wrong CPU, a wrong libc or a
  missing shared library fails during installation, not on every later call.
- **PATH**: when the install directory is not yet on `PATH`, `--path` appends a
  marked block to the startup file of your shell (`~/.bashrc`, `~/.zshrc`,
  `~/.profile`) — idempotently; without `--path` nothing is edited outside the
  install directory and the installer prints the exact `export` line. `--no-path`
  forbids touching a dotfile.

The installer lets you choose how SurrealDB runs (docker compose, plain
`docker run`, `podman`, or your own instance) and, in an interactive run, asks
for the image, port and credentials; pressing Enter at the password prompt
generates a random one. The managed instance is keyed by its port (container
and volume `cm-surrealdb-<port>`), so several instances — or a dev stack and a
user install — coexist on one machine; an already-initialized storage asks for
its original password instead of silently rejecting a new one. Flags and
environment variables skip the corresponding question — required for
non-interactive runs (`--yes`). `sh install.sh --help` lists everything:

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

## Configuration

Everything lives in `$CODEMASTER_HOME` (default `~/.codemaster`) and belongs to
the user who runs `cm`:

| Path | What |
|---|---|
| `config.toml` | the configuration; written by `install.sh`, mode `0600` (it holds the database password) |
| `docker-compose.yml` | the managed SurrealDB instance, in `--db compose` mode |
| `daemon.sock`, `daemon.lock` | the running daemon's IPC socket and single-owner lock |
| `logs/daemon.log` | daemon log — `cm daemon start` quotes its last lines when the daemon dies |
| `skills/` | staged agent skills + `skills-manifest.json` |

Three commands answer everything about it:

```bash
cm config explain   # every effective value + where it came from (file/env/default), secrets redacted
cm config init      # write a template of every key this build reads (coordinates left empty)
cm doctor           # local report: configuration, permissions, database reachability, daemon state
```

**There is no built-in database address or credential**
([ADR-0027](docs/adr/0027-no-builtin-database-coordinates.md)): all five
`[storage]` coordinates must be set before the daemon starts, and until then
`cm daemon start` says exactly which keys are missing instead of contacting a
guessed port. `install.sh` writes the section for you; a scripted run passes
`--user`/`--password` explicitly. An unset key that nobody wrote is reported by
`cm doctor` as `storage_not_configured`, and a key that this build does not know
(such as a typo) is reported as `unknown_key` with the nearest sibling —
`docs/architecture/configuration.md` is the reference.

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
into places nobody chose.
