#!/bin/sh
set -eu

# Install Nullgate as a uv tool. Everything after this one shell artifact is
# Python in the src/nullgate package: there are no companion scripts to drop
# beside a launcher anymore, so the whole install is a single `uv tool install`.
#
# Env overrides:
#   NULLGATE_VERSION   install a specific published version (e.g. 1.0.1).
#   NULLGATE_DIST_URL  override the public distribution root.
#   NULLGATE_PACKAGE   fully override the `uv tool install` package spec.
#   NULLGATE_PREFIX    install the console script into $PREFIX/bin.
#   UV_TOOL_DIR / UV_TOOL_BIN_DIR  standard uv tool isolation (honored).

# Keep uv usable in constrained hosting cgroups where process and thread counts
# are much lower than the CPU count reported by the host. Callers can raise any
# of these limits explicitly on less restricted systems.
export RAYON_NUM_THREADS=${RAYON_NUM_THREADS:-1}
export UV_CONCURRENT_BUILDS=${UV_CONCURRENT_BUILDS:-1}
export UV_CONCURRENT_CACHE_READS=${UV_CONCURRENT_CACHE_READS:-1}
export UV_CONCURRENT_DOWNLOADS=${UV_CONCURRENT_DOWNLOADS:-1}
export UV_CONCURRENT_INSTALLS=${UV_CONCURRENT_INSTALLS:-1}

VERSION=${NULLGATE_VERSION:-}
DIST_URL=${NULLGATE_DIST_URL:-https://shadowdocks.github.io/nullgate-dist}
DIST_URL=${DIST_URL%/}
PACKAGE=${NULLGATE_PACKAGE:-}
PREFIX=${NULLGATE_PREFIX:-"$HOME/.local"}
BIN_DIR="$PREFIX/bin"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nullgate-install.XXXXXX")

cleanup() {
  status=$?
  trap - 0 HUP INT TERM
  rm -rf "$TEMP_DIR"
  exit "$status"
}
trap cleanup 0 HUP INT TERM

command -v curl >/dev/null 2>&1 || {
  printf '%s\n' "nullgate: curl is required" >&2
  exit 1
}

manifest_value() {
  key=$1
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$2"
}

if [ -z "$PACKAGE" ]; then
  if [ -n "$VERSION" ]; then
    case "$VERSION" in v*) VERSION=${VERSION#v} ;; esac
    MANIFEST_URL="$DIST_URL/releases/$VERSION/manifest.json"
  else
    MANIFEST_URL="$DIST_URL/stable.json"
  fi

  MANIFEST="$TEMP_DIR/manifest.json"
  MANIFEST_REQUEST="$MANIFEST_URL?ts=$(date +%s)"
  curl -fsSL "$MANIFEST_REQUEST" -o "$MANIFEST" || {
    printf 'nullgate: failed to fetch release manifest: %s\n' "$MANIFEST_URL" >&2
    exit 1
  }
  RELEASE_VERSION=$(manifest_value version "$MANIFEST")
  WHEEL_PATH=$(manifest_value wheel "$MANIFEST")
  EXPECTED_SHA256=$(manifest_value sha256 "$MANIFEST")
  [ -n "$RELEASE_VERSION" ] && [ -n "$WHEEL_PATH" ] && [ -n "$EXPECTED_SHA256" ] || {
    printf 'nullgate: release manifest is incomplete\n' >&2
    exit 1
  }
  [ -z "$VERSION" ] || [ "$VERSION" = "$RELEASE_VERSION" ] || {
    printf 'nullgate: requested version %s but manifest describes %s\n' "$VERSION" "$RELEASE_VERSION" >&2
    exit 1
  }
  WHEEL_FILE=${WHEEL_PATH#releases/"$RELEASE_VERSION"/}
  case "$WHEEL_PATH:$WHEEL_FILE" in
    releases/"$RELEASE_VERSION"/nullgate-*.whl:nullgate-*.whl)
      case "$WHEEL_FILE" in
        *[!A-Za-z0-9._+-]*)
          printf 'nullgate: release manifest contains an unsafe wheel path\n' >&2
          exit 1
          ;;
      esac
      ;;
    *) printf 'nullgate: release manifest contains an unsafe wheel path\n' >&2; exit 1 ;;
  esac

  WHEEL="$TEMP_DIR/$WHEEL_FILE"
  curl -fsSL "$DIST_URL/$WHEEL_PATH" -o "$WHEEL" || {
    printf 'nullgate: failed to download release %s\n' "$RELEASE_VERSION" >&2
    exit 1
  }
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(sha256sum "$WHEEL" | sed 's/[[:space:]].*$//')
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(shasum -a 256 "$WHEEL" | sed 's/[[:space:]].*$//')
  elif command -v sha256 >/dev/null 2>&1; then
    ACTUAL_SHA256=$(sha256 -q "$WHEEL")
  else
    printf 'nullgate: sha256sum, shasum, or sha256 is required\n' >&2
    exit 1
  fi
  [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || {
    printf 'nullgate: release checksum verification failed\n' >&2
    exit 1
  }
  PACKAGE=$WHEEL
  VERSION=$RELEASE_VERSION
fi

if ! command -v uv >/dev/null 2>&1; then
  printf 'nullgate: uv not found; installing from https://astral.sh/uv\n'
  curl -LsSf https://astral.sh/uv/install.sh | sh
  for uv_bin in "${XDG_BIN_HOME:-}" "$HOME/.local/bin" "$HOME/.cargo/bin"; do
    [ -n "$uv_bin" ] && [ -x "$uv_bin/uv" ] || continue
    case ":$PATH:" in *":$uv_bin:"*) ;; *) PATH="$uv_bin:$PATH" ;; esac
  done
  command -v uv >/dev/null 2>&1 || {
    printf 'nullgate: uv install failed; install it manually and re-run\n' >&2
    exit 1
  }
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'nullgate: python3 not found; installing a managed Python via uv\n'
  if ! uv python install --preview-features python-install-default --default; then
    printf 'nullgate: python3 install failed; install it manually and re-run\n' >&2
    exit 1
  fi
  py_shim_dir=
  for py_bin in "${XDG_BIN_HOME:-}" "$HOME/.local/bin"; do
    [ -n "$py_bin" ] && [ -x "$py_bin/python3" ] || continue
    case ":$PATH:" in *":$py_bin:"*) ;; *) PATH="$py_bin:$PATH" ;; esac
    py_shim_dir="$py_bin"
  done
  command -v python3 >/dev/null 2>&1 || {
    printf 'nullgate: python3 install failed; install it manually and re-run\n' >&2
    exit 1
  }
  if [ -n "$py_shim_dir" ]; then
    printf 'nullgate: managed Python at %s; keep it on PATH for future sessions\n' "$py_shim_dir"
  fi
fi

# Reflect NULLGATE_PREFIX (and the temp tool dirs used by tests) into uv so
# the console script lands where the caller asked.
export UV_TOOL_BIN_DIR=${UV_TOOL_BIN_DIR:-"$BIN_DIR"}
export UV_TOOL_DIR=${UV_TOOL_DIR:-"$PREFIX/share/uv/tools"}
mkdir -p "$BIN_DIR"

# The destination of the console script must not be a directory.
# uv owns this path and installs a symlink into its tool
# environment, so a symlink or a regular file here is the normal state after a
# previous install and --force replaces it. Refusing those broke every upgrade.
# A directory is the one case worth catching, since uv cannot replace it and
# its error is far less clear than this one.
for destination in "$UV_TOOL_BIN_DIR/nullgate"; do
  if [ -d "$destination" ]; then
    printf 'nullgate: refusing unsafe install destination: %s\n' "$destination" >&2
    exit 1
  fi
done

# uv owns the atomicity of the tool environment: it builds into its own staging
# area and only swaps the console script in once the install succeeds, so a
# failure leaves any previous installation in place. Copying the console script
# aside here would not add a guarantee, since that script is only a shim into
# the tool environment uv would have already replaced.
if ! uv tool install --force "$PACKAGE"; then
  printf 'nullgate: install failed; the previous installation was left in place\n' >&2
  exit 1
fi

if [ -n "$VERSION" ]; then
  printf 'Installed nullgate %s to %s\n' "$VERSION" "$UV_TOOL_BIN_DIR/nullgate"
else
  printf 'Installed nullgate to %s\n' "$UV_TOOL_BIN_DIR/nullgate"
fi
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'Add %s to PATH: export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac

# Any remaining arguments are handed to nullgate, so a single piped command
# can install and then run (curl ... | sh -s -- open . --port 4822 --slot 1).
if [ "$#" -gt 0 ]; then
  rm -rf "$TEMP_DIR"
  trap - 0 HUP INT TERM
  exec "$UV_TOOL_BIN_DIR/nullgate" "$@"
fi
