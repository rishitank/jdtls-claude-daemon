# jdtls-claude-daemon

Persistent daemon proxy for Eclipse JDT Language Server (jdtls), solving two fundamental problems with Java development in Claude Code:

## Problems Solved

### 1. Cold-start latency

jdtls takes 60–90 seconds to start for large Maven/Gradle projects. Claude Code's LSP harness restarts the server on every new session. With this daemon, jdtls starts once and stays alive — subsequent connections respond in milliseconds.

### 2. `jdt://` URIs are unreachable from Claude Code

When Go-To-Definition lands on an external JAR (a library class with no attached sources), jdtls returns a `jdt://` URI. Claude Code's harness can only open `file://` URIs — `jdt://` is silently dropped. The daemon intercepts these responses, calls `java/classFileContents` internally, writes the decompiled source to `/tmp/jdtls-decompiled/`, and rewrites the URI to `file://` before forwarding to the harness.

## Architecture

```
Claude Code harness
     │ stdio
     ▼
 bin/jdtls  (wrapper — stdio ↔ Unix socket bridge)
     │ /tmp/jdtls-daemon.sock
     ▼
 bin/jdtls-daemon  (persistent daemon)
     │ subprocess stdin/stdout
     ▼
 jdtls  (real Eclipse JDT Language Server)
```

## Features

- **Instant reconnect**: cached `initialize` response replayed in <1 ms on second connection
- **Automatic `jdt://` → `file://` rewrite**: decompiled sources written to `/tmp/jdtls-decompiled/`
- **Decompilation cache**: same class rewrites instantly within a session
- **Auto-restart**: if jdtls crashes the daemon restarts it transparently — the harness never sees an error
- **Fake shutdown/exit**: harness `shutdown`/`exit` are intercepted so jdtls stays alive
- **Write serialization**: `client_write_lock` prevents interleaved LSP frames from concurrent writes
- **Pending GC**: `classFileContents` requests that receive no response within 30 s are expired — client never hangs
- **Patched initialize**: injects `classFileContentsSupport`, `downloadSources`, and `downloadJavadoc` into every `initialize` request automatically
- **PATH-based binary discovery**: finds the real `jdtls` binary by scanning `PATH` (skips own directory); respects `JDTLS_BIN` env override

## Requirements

- Python 3.8+
- jdtls installed and on `PATH` (e.g. `brew install jdtls` on macOS)
- Claude Code with a Java LSP plugin:
  - [Anthropic official `jdtls-lsp`](https://github.com/anthropics/claude-plugins-official) (user-scoped)
  - [Piebald-AI `jdtls@claude-code-lsps`](https://github.com/Piebald-AI/claude-code-lsps) (project-scoped)

## Installation

```bash
git clone https://github.com/rishitank/jdtls-claude-daemon.git
cd jdtls-claude-daemon
./install.sh
```

The script copies `bin/jdtls` and `bin/jdtls-daemon` to `~/.local/bin/` (override with `JDTLS_DAEMON_INSTALL_DIR`).

**Critical**: the install directory must appear on `PATH` *before* the real `jdtls` binary:

```bash
export PATH="$HOME/.local/bin:$PATH"
which jdtls   # must print ~/.local/bin/jdtls
```

## Plugin configuration

### Piebald-AI/claude-code-lsps

Update `jdtls/.lsp.json` in your project:

```json
{
    "java": {
        "command": "jdtls",
        "args": [],
        "extensionToLanguage": {".java": "java"},
        "transport": "stdio",
        "initializationOptions": {},
        "settings": {},
        "startupTimeout": 300000,
        "shutdownTimeout": 15000,
        "maxRestarts": 100
    }
}
```

Key changes from defaults:
- `startupTimeout` 90000 → 300000 ms: large Maven projects need time on the first cold start
- `maxRestarts` 3 → 100: the wrapper absorbs reconnects without consuming this counter, but a high value prevents false exhaustion during initial daemon setup

### Anthropic official jdtls-lsp plugin

No `.lsp.json` to configure. The daemon wrapper absorbs reconnects so `maxRestarts` is never incremented.

## SIGUSR1: Force fresh initialize

If capabilities feel stale after a significant project restructure:

```bash
kill -USR1 $(cat /tmp/jdtls-daemon.pid)
```

This clears the cached `initialize` response. The next client connection performs a fresh live initialize from jdtls.

## Logs

| File | Contents |
|------|----------|
| `/tmp/jdtls_wrapper.log` | Wrapper stdin/stdout framing events |
| `/tmp/jdtls_daemon.log` | Daemon: connections, initialize cache, jdt:// rewrites, GC |
| `/tmp/jdtls_daemon.log.jdtls.err` | jdtls stderr (project import errors, JVM output) |

## How it works

### Wrapper (`bin/jdtls`)

Stands in for the real `jdtls` binary on `PATH`. When Claude Code spawns it:

1. Checks if `jdtls-daemon` is running; starts it if not.
2. Connects to the daemon's Unix socket.
3. Bridges harness stdio ↔ daemon socket.
4. Caches the `initialize` frame (re-serialized to guarantee completeness).
5. On daemon socket EOF: reconnects and replays the cached `initialize` frame — the harness never sees a disconnect.

### Daemon (`bin/jdtls-daemon`)

Long-running process that holds one jdtls JVM alive:

1. **First connection**: patches and forwards `initialize` to jdtls; caches the response.
2. **Subsequent connections**: replays the cached response immediately (rewrites `id` to match the new request).
3. **`initialized` notification**: forwarded to jdtls exactly once per lifetime.
4. **`shutdown`/`exit`**: intercepted; fake success sent to harness; jdtls keeps running.
5. **`jdt://` detection**: holds the definition response, sends internal `java/classFileContents` (IDs 100000+), writes decompiled `.java` to `/tmp/jdtls-decompiled/`, rewrites URI, forwards rewritten response.
6. **jdtls crash**: `_restart_jdtls()` clears state and spawns a new process.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `JDTLS_DAEMON_INSTALL_DIR` | `~/.local/bin` | Install destination for `install.sh` |
| `JDTLS_BIN` | auto-detected from `PATH` | Path to the real `jdtls` binary |
