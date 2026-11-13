#!/usr/bin/env bash
# tests/fm-opencode-stale-lock.test.sh - a state/.lock naming a dead owner pid
# keeps the OpenCode arm plugin read-only, and both the plugin and the OpenCode
# turn-end guidance say so visibly and name bin/fm-lock.sh, without touching
# the lock.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-stale-lock.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

dead_pid() {
  local pid
  sleep 0 & pid=$!
  wait "$pid" 2>/dev/null
  printf '%s\n' "$pid"
}

make_fixture() {
  local dir=$1
  mkdir -p "$dir/repo/bin" "$dir/home/state" "$dir/home/config"
  git init -q -b main "$dir/repo"
  : > "$dir/repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$dir/repo/bin/"
  cat > "$dir/repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
SH
  chmod +x "$dir/repo/bin/fm-watch-arm.sh"
}

test_plugin_surfaces_stale_lock() {
  command -v node >/dev/null 2>&1 || { printf 'skip: node not found\n'; return 0; }
  local dir="$TMP/plugin" pid out
  make_fixture "$dir"
  pid=$(dead_pid)
  printf '%s\n' "$pid" > "$dir/home/state/.lock"
  cat > "$TMP/driver.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const prompts = [];
const client = { session: { promptAsync: async ({ body }) => { prompts.push(body.parts[0].text); } } };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
for (let i = 0; i < 250 && prompts.length === 0; i += 1) await new Promise((r) => setTimeout(r, 20));
console.log(JSON.stringify({ status, prompts }));
JS
  out=$(FM_ROOT_OVERRIDE="$dir/repo" FM_HOME="$dir/home" WORKTREE="$dir/repo" FM_ARM_LOG="$dir/arm.log" \
    NODE_NO_WARNINGS=1 PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js" node "$TMP/driver.mjs" 2>/dev/null | tail -n 1)
  case "$out" in *'"status":"read-only"'*) ;; *) fail "plugin must refuse read-only on a dead lock owner: $out" ;; esac
  case "$out" in *"owner pid $pid is dead"*"bin/fm-lock.sh"*) ;; *) fail "plugin must surface the stale lock naming bin/fm-lock.sh: $out" ;; esac
  [ ! -e "$dir/arm.log" ] || fail "plugin armed despite the stale lock"
  [ "$(cat "$dir/home/state/.lock")" = "$pid" ] || fail "plugin changed the lock file"
  pass "OpenCode arm plugin surfaces a dead-owner lock and leaves it alone"
}

test_guard_text_names_fm_lock() {
  local home="$TMP/guard" pid out
  mkdir -p "$home/state" "$home/config"
  pid=$(dead_pid)
  printf '%s\n' "$pid" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness opencode --repair-line 2>/dev/null)
  case "$out" in *"lock is stale"*"bin/fm-lock.sh"*) ;; *) fail "opencode guidance must name the stale lock and bin/fm-lock.sh: $out" ;; esac
  case "$out" in *"plugin arm after idle"*) fail "opencode guidance must not promise the plugin will arm: $out" ;; esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness opencode --repair-line 2>/dev/null)
  case "$out" in *"plugin arm after idle"*) ;; *) fail "live lock owner must keep the ordinary guidance: $out" ;; esac
  [ "$(cat "$home/state/.lock")" = "$$" ] || fail "guidance changed the lock file"
  pass "OpenCode turn-end guidance names bin/fm-lock.sh for a stale lock"
}

test_plugin_surfaces_stale_lock
test_guard_text_names_fm_lock
