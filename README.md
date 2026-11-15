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

Requirements for the published binaries: Linux on `x86_64` with **glibc >= 2.35**
(Ubuntu 22.04, Debian 12) plus Docker,
Podman or your own SurrealDB 4.0.0 for the database. `cm doctor --deep` checks
the installation, the coordinates, the database port and whether these binaries
actually run here.

Release binaries are published for Linux `x86_64` only; on macOS or any other
platform build for this host with `--from-source`. One command installs `cm`,
`cm-mcp`, `cm-daemon` and can start the local SurrealDB service:

```bash
curl -fsSL https://raw.githubusercontent.com/lvl73/codemaster-dist/master/install.sh -o install.sh
sh install.sh
```

Run it as the user who will use CodeMaster — **no `sudo`**. The daemon, its
socket, `config.toml` and the staged skills live in the home of whoever ran the
command, so a root install is invisible to your own `cm`. The installer picks a
writable directory that is already on `PATH` (`~/.local/bin` by default);
`/usr/local/bin` is used only for a root install or after an explicit
confirmation.

What the installer decides on its own:

- **Platform and asset**: `uname` plus `ldd`/musl probes select
  `cm-<triple>.tar.gz`; a host below the glibc baseline or outside the release
  is refused with the concrete alternatives (`--from-source`, `--triple`,
  `--libc`, `--allow-unsupported`) instead of a binary whose only output is a
  loader error.
- **Checksums**: every downloaded asset is verified against its published
  `.sha256`; a missing checksum aborts unless `--allow-unverified` is given.
- **It runs what it downloaded**: `cm --version` is executed before anything
  reaches `PATH`, so a wrong CPU or libc fails during installation, not later.
- **PATH**: with `--path` the install directory is added to your shell's
  startup file idempotently; otherwise nothing outside the install directory
  is edited and the exact `export` line is printed.

The installer lets you choose how SurrealDB runs (docker compose, plain
`docker run`, `podman`, or your own instance) and, in an interactive run, asks
for the image, port and credentials; pressing Enter at the password prompt
generates a random one. Several instances — or a dev stack and a user install —
coexist on one machine, keyed by port; an already-initialized storage asks for
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

and register `cm-mcp` as an MCP server. Prefer the agent's own command, which
keeps unrelated settings intact; the installer prints the same hint with the
installed path:

```bash
opencode mcp add codemaster -- "$(command -v cm-mcp)"        # this project
opencode mcp add codemaster --global -- "$(command -v cm-mcp)"
```

Then make sure the entry is in OpenCode's native V2 shape and that `codemode`
is off — with the default `true` the cm tools are reachable only through Code
Mode, not as `codemaster_*` tools the model can pick (the installer output
carries the full snippet):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "codemaster": {
        "type": "local",
        "command": ["/abs/path/to/cm-mcp"],
        "cwd": ".",
        "codemode": false
      }
    }
  }
}
```

Verify with `opencode mcp list` (`codemaster connected`) and, in a new session,
by asking the agent to list its `codemaster_` tools. Configuration reloads
without a restart. The adapter resolves the project from its working directory,
so `cwd` decides which repository a question is about.

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

**There is no built-in database address or credential**:
all five
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
cm skill install --agent opencode --scope project --yes --policy
cm skill status --agent claude --scope global              # ok / modified / outdated
cm skill remove --agent opencode                           # deletes only our files
cm doctor --agent opencode                           # why the agent does not see cm
```

One consented step further: `cm init --integration opencode --yes` performs
the same pieces the separate commands own — skills, the policy block, the
project MCP registration (`codemode: false`, strict-JSON merge) — records each
in `.codemaster/integration.lock.json`, previews with `--dry-run`, and is
reversible with `cm init --integration-remove`. `--with skills,policy,mcp-config,plugin`
chooses the pieces explicitly; the reminder plugin changes the agent's own
behaviour and is never installed by default. Plain `cm init`
still installs nothing, so CI behaviour is unchanged. If the agent ends up not
seeing cm, `cm doctor --agent opencode` names what is proven, what is missing,
and what cm cannot observe from here.

The reminder plugin nudges an agent back to cm after
three consecutive grep/read/glob fallbacks — once per session, never blocking,
and silent when no `codemaster_*` tools are visible to the model. To reproduce
it in your own repository:

```bash
# from the project root, with the daemon running and the project registered
cm init                                          # idempotent; registers if new
cm init --integration opencode --with skills,policy,mcp-config,plugin --yes
cm doctor --agent opencode                       # the plugin row must read ok
```

The plugin itself ships embedded in the `cm` binary — there is nothing to
download. `--with plugin` writes it to `.opencode/plugins/codemaster-adopt/index.ts`,
which OpenCode V2 discovers automatically (no config array needed); a file you
edited is never overwritten. A new session is enough for OpenCode to pick it
up. Silence the plugin without uninstalling: add `"-codemaster.adopt"` to
`"plugins"` in `opencode.json`. Take everything back with
`cm init --integration-remove`.

Scope is never guessed: non-interactively `cm skill install` requires both
`--agent` and `--scope` and otherwise refuses, so CI and agents cannot write
into places nobody chose. `--policy` adds a short, always-loaded CodeMaster rule
block to the project's `AGENTS.md`/`CLAUDE.md` (idempotent, removed by
`cm skill remove`, your other text untouched); `--policy-only` installs just
that block.
