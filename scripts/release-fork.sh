#!/usr/bin/env bash
# scripts/release-fork.sh — Self-contained npm publish for forks
#
# Bundles hindsight-embed/ + hindsight-api-slim/ into the openclaw plugin's
# npm tarball. Customers install with
#   openclaw plugins install @<NAMESPACE>/hindsight-openclaw
# and the daemon spawns from the bundled Python source via embedPackagePath,
# so no separate PyPI publish is required and the openclaw_auth.py resolver
# ships with the plugin.
#
# This script is idempotent. On the first run it patches the plugin to rename
# itself, advertise the bundled directories in package.json#files, and add a
# bundled-source detector. Subsequent runs detect the patches are already in
# place and skip them.
#
# Prerequisites:
#   1. npm logged in (`npm login`) under the namespace owner account
#   2. Run from a non-main branch (recommend a dedicated fork-publish branch)
#   3. Clean working tree
#   4. The `fork` git remote points at your fork (gh repo fork sets this up)
#
# Usage:
#   scripts/release-fork.sh <version> [<namespace>] [--no-publish]
#   HINDSIGHT_FORK_NAMESPACE=youchi1 scripts/release-fork.sh 0.6.7-fork.1
#
# Examples:
#   scripts/release-fork.sh 0.6.7-fork.5 youchi1
#   scripts/release-fork.sh 0.6.7-fork.5 youchi1 --no-publish   # build tarball only, for VPS smoke-testing

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die() { print_error "$1"; exit 1; }

# ---------- args ----------
NO_PUBLISH=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --no-publish) NO_PUBLISH=true ;;
    -h|--help)
      sed -n '2,28p' "$0"; exit 0 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]}"

[ $# -ge 1 ] || die "Usage: $0 <version> [<namespace>] [--no-publish]"
VERSION="$1"
NAMESPACE="${2:-${HINDSIGHT_FORK_NAMESPACE:-}}"
[ -n "$NAMESPACE" ] || die "namespace required (arg 2 or HINDSIGHT_FORK_NAMESPACE env var)"

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._]+)?$ ]] \
  || die "version must be semver (optionally with a -prerelease suffix), got: $VERSION"

SCOPED_NAME="@${NAMESPACE}/hindsight-openclaw"
TAG="v${VERSION}-fork"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_DIR="$REPO_ROOT/hindsight-integrations/openclaw"
PKG_JSON="$PLUGIN_DIR/package.json"
INDEX_TS="$PLUGIN_DIR/src/index.ts"
BUNDLED_TS="$PLUGIN_DIR/src/bundled-source.ts"

# ---------- preflight ----------
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
[ "$CURRENT_BRANCH" != "main" ] || die "do not run on main; use a fork-publish branch"

[ -z "$(git -C "$REPO_ROOT" status -s)" ] || die "working tree not clean; commit or stash first"

git -C "$REPO_ROOT" rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists"

command -v node >/dev/null || die "node not found"
command -v npm  >/dev/null || die "npm not found"
if NPM_USER="$(npm whoami --registry=https://registry.npmjs.org/ 2>/dev/null)"; then
  print_info "npm logged in as: $NPM_USER"
else
  print_warn "npm not logged in, launching npm login..."
  npm login --registry=https://registry.npmjs.org/
  NPM_USER="$(npm whoami --registry=https://registry.npmjs.org/ 2>/dev/null)" \
    || die "npm login did not complete successfully"
  print_info "npm logged in as: $NPM_USER"
fi

if git -C "$REPO_ROOT" remote get-url fork >/dev/null 2>&1; then
  PUSH_REMOTE="fork"
else
  PUSH_REMOTE="origin"
  ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN_URL" in
    *vectorize-io/hindsight*)
      die "no 'fork' remote and origin points at upstream ($ORIGIN_URL); add a fork remote first (gh repo fork --remote-name=fork)" ;;
  esac
fi
print_info "Push remote: $PUSH_REMOTE"
print_info "Will publish $SCOPED_NAME@$VERSION"

# ---------- idempotent source patches ----------
print_info "Applying fork patches (idempotent)..."

# package.json: rename + ensure files entries + point repository at the fork
# so the npm "Repository" / `npm repo` / provenance metadata leads to the
# right source for users of @<NS>/hindsight-openclaw.
FORK_REPO_URL="git+https://github.com/${NAMESPACE}/hindsight.git"
FORK_BUGS_URL="https://github.com/${NAMESPACE}/hindsight/issues"
FORK_HOME_URL="https://github.com/${NAMESPACE}/hindsight#readme"
PKG_PATH="$PKG_JSON" \
PKG_NAME="$SCOPED_NAME" \
PKG_REPO="$FORK_REPO_URL" \
PKG_BUGS="$FORK_BUGS_URL" \
PKG_HOME="$FORK_HOME_URL" \
node --input-type=module -e '
  import fs from "fs";
  const path = process.env.PKG_PATH;
  const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
  let changed = false;
  if (pkg.name !== process.env.PKG_NAME) { pkg.name = process.env.PKG_NAME; changed = true; }
  const files = new Set(pkg.files || []);
  for (const f of ["hindsight-embed", "hindsight-api-slim"]) {
    if (!files.has(f)) { files.add(f); changed = true; }
  }
  pkg.files = [...files];
  if (!pkg.repository || pkg.repository.url !== process.env.PKG_REPO) {
    pkg.repository = { type: "git", url: process.env.PKG_REPO };
    changed = true;
  }
  if (!pkg.bugs || pkg.bugs.url !== process.env.PKG_BUGS) {
    pkg.bugs = { url: process.env.PKG_BUGS };
    changed = true;
  }
  if (pkg.homepage !== process.env.PKG_HOME) {
    pkg.homepage = process.env.PKG_HOME;
    changed = true;
  }
  if (changed) {
    fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
    console.log("package.json patched");
  } else {
    console.log("package.json already patched");
  }
'

# bundled-source.ts: create if missing
if [ ! -f "$BUNDLED_TS" ]; then
  cat > "$BUNDLED_TS" <<'EOTS'
import { existsSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

/**
 * When the plugin is published with bundled Python source (the fork-release
 * publish flow), hindsight-embed/ sits as a sibling of dist/. Returns its
 * absolute path if present, otherwise undefined so the plugin falls back to
 * the configured embedVersion + uvx behavior.
 */
export function detectBundledPythonRoot(): string | undefined {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const candidate = join(here, "..", "hindsight-embed");
    if (existsSync(candidate) && existsSync(join(candidate, "pyproject.toml"))) {
      return candidate;
    }
  } catch {
    // fileURLToPath can throw in non-ESM bundlers; fall through.
  }
  return undefined;
}
EOTS
  print_info "created src/bundled-source.ts"
fi

# index.ts: add import + use as fallback. Validate both anchors before any
# mutation so we never leave the file half-patched on failure.
if ! grep -q 'detectBundledPythonRoot' "$INDEX_TS"; then
  IMPORT_ANCHOR='import { defaultOpenClawRoot } from "./backfill-lib.js";'
  NEW_IMPORT='import { detectBundledPythonRoot } from "./bundled-source.js";'
  EMBED_OLD='    embedPackagePath: config.embedPackagePath,'
  EMBED_NEW='    embedPackagePath: config.embedPackagePath ?? detectBundledPythonRoot(),'
  grep -qF "$IMPORT_ANCHOR" "$INDEX_TS" \
    || die "could not find backfill-lib import anchor in index.ts; manual patch needed"
  grep -qF "$EMBED_OLD"     "$INDEX_TS" \
    || die "could not find embedPackagePath assignment in getPluginConfig; manual patch needed"

  awk -v a="$IMPORT_ANCHOR" -v n="$NEW_IMPORT" -v old="$EMBED_OLD" -v new="$EMBED_NEW" '
    $0 == a && !import_done { print; print n; import_done = 1; next }
    $0 == old { print new; next }
    { print }
  ' "$INDEX_TS" > "$INDEX_TS.tmp" && mv "$INDEX_TS.tmp" "$INDEX_TS"

  print_info "patched src/index.ts (added auto-detect for bundled Python)"
fi

# ---------- bump versions ----------
print_info "Bumping versions to $VERSION..."

PKG_PATH="$PKG_JSON" PKG_VERSION="$VERSION" node --input-type=module -e '
  import fs from "fs";
  const path = process.env.PKG_PATH;
  const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
  pkg.version = process.env.PKG_VERSION;
  fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
'

# PEP 440 forbids the npm-style `-` prerelease separator. Translate it to the
# `+local-version` form (e.g. `0.6.7-fork.1` -> `0.6.7+fork.1`) so uv/pip can
# parse the bundled pyprojects on customer VPSes.
PY_VERSION="${VERSION/-/+}"
bump_pyproject() {
  local f="$1"
  if [ -f "$f" ]; then
    sed -i.bak "s/^version = \".*\"/version = \"$PY_VERSION\"/" "$f"
    rm "$f.bak"
  else
    print_warn "$f not found, skipping"
  fi
}
bump_pyproject "$REPO_ROOT/hindsight-api-slim/pyproject.toml"
bump_pyproject "$REPO_ROOT/hindsight-embed/pyproject.toml"

# Refresh uv.lock to match the new pyproject versions. The pre-commit lint
# hook runs `uv sync` later; if we don't refresh the lock here it'll be
# rewritten *after* `git add -A`, leaving a dirty working tree post-commit.
if command -v uv >/dev/null; then
  print_info "Refreshing uv.lock..."
  (cd "$REPO_ROOT" && uv lock --quiet)
fi

cleanup_bundle() {
  rm -rf "$PLUGIN_DIR/hindsight-embed" "$PLUGIN_DIR/hindsight-api-slim"
}
trap cleanup_bundle EXIT

# ---------- build plugin ----------
cd "$PLUGIN_DIR"
print_info "Building plugin (tsc)..."
npm run build >/dev/null

# ---------- bundle Python source into plugin dir ----------
# rsync (rather than cp -R + find … rm) skips heavy caches in one pass — a
# stale `.venv` next to the source can be hundreds of MB.
print_info "Bundling Python source into plugin tarball staging..."
rm -rf hindsight-embed hindsight-api-slim
RSYNC_EXCLUDES=(
  --exclude=".venv"
  --exclude=".ruff_cache"
  --exclude=".pytest_cache"
  --exclude=".mypy_cache"
  --exclude="tests"
  --exclude="dist"
  --exclude="build"
  --exclude="__pycache__"
  --exclude="*.pyc"
  --exclude="*.egg-info"
)
rsync -a "${RSYNC_EXCLUDES[@]}" "$REPO_ROOT/hindsight-embed/"     ./hindsight-embed/
rsync -a "${RSYNC_EXCLUDES[@]}" "$REPO_ROOT/hindsight-api-slim/"  ./hindsight-api-slim/

# ---------- pack (always) + publish (unless --no-publish) ----------
print_info "Running npm pack to build tarball..."
PACK_OUT="$(npm pack --json)"
TARBALL="$(echo "$PACK_OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[0].filename))')"
TARBALL_PATH="$PLUGIN_DIR/$TARBALL"
TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
print_info "tarball: $TARBALL_PATH ($TARBALL_SIZE)"

if [ "$NO_PUBLISH" = "true" ]; then
  echo
  print_info "🧪 --no-publish: skipping npm publish, git commit, tag, push."
  print_info ""
  print_info "Tarball ready for VPS testing:"
  print_info "  $TARBALL_PATH"
  print_info ""
  print_info "Test on VPS (example):"
  print_info "  scp $TARBALL_PATH root@<vps>:/tmp/"
  print_info "  ssh root@<vps> 'su - <user> -c \"openclaw plugins install --force /tmp/$TARBALL\"'"
  print_info "  ssh root@<vps> 'systemctl restart openclaw-gateway'"
  print_info ""
  print_info "Working tree is dirty (version bumps). To clean up after testing:"
  print_info "  git restore hindsight-api-slim/pyproject.toml hindsight-embed/pyproject.toml \\"
  print_info "              hindsight-integrations/openclaw/package.json uv.lock"
  print_info "  rm $TARBALL_PATH"
  cleanup_bundle
  trap - EXIT
  exit 0
fi

print_info "Publishing $SCOPED_NAME@$VERSION (--access public --tag latest)..."
# --tag latest: prerelease versions ($VERSION includes a -fork.N suffix) need
# an explicit dist-tag, and we want unversioned installs to land on this fork.
npm publish --access public --tag latest "$TARBALL"

rm -f "$TARBALL"
cleanup_bundle
trap - EXIT

# ---------- commit + tag + push ----------
cd "$REPO_ROOT"
print_info "Committing release..."
git add -A
git commit -m "Release fork v$VERSION ($SCOPED_NAME)"
git tag -a "$TAG" -m "Fork release v$VERSION ($SCOPED_NAME)"

print_info "Pushing to $PUSH_REMOTE..."
git push "$PUSH_REMOTE" HEAD
git push "$PUSH_REMOTE" "$TAG"

echo
print_info "✅ Released $SCOPED_NAME@$VERSION"
print_info "   Tag: $TAG"
print_info "   Install on a customer VPS:"
print_info "     openclaw plugins install $SCOPED_NAME"
print_info "     openclaw config set plugins.entries.hindsight-openclaw.config.llmAuthSource openclaw"
print_info "     openclaw config set plugins.entries.hindsight-openclaw.config.llmProvider <provider>"
print_info "     openclaw gateway --force"
