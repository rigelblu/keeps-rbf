#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ONE level up: this script lives at <repo>/scripts/, so the repo root is its parent.
# It was `../..`, which resolved to /Volumes/Tom's HDD/src/rb — the directory holding EVERY
# product's store. That has an `rb-drive/` too, so the mistake looked plausible right up until
# the projects/ guard below refused it. Without that guard this would have mirrored the whole
# multi-product store into one product's Drive folder, with --delete.
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "$repo_root"

# Cap how many files a single mirror may delete, as a backstop against a runaway
# --delete. Raise it for a legitimately large cleanup: RB_DRIVE_MAX_DELETE=500 ...
max_delete="${RB_DRIVE_MAX_DELETE:-100}"

usage() {
  cat <<'USAGE'
Usage: zed-rbf/scripts/sync-rb-drive.sh [--dry-run] <command>

Mirror the rb-drive directory to a Google Drive destination with rsync.

Commands:
  remote      Back up rb-drive into .rb-drive-remote/ (faithful private mirror).
  public      Publish rb-drive contents (agents/, projects/) into .rb-drive-public-share/ (VCS + secrets excluded).

Options:
  -n, --dry-run  Show what rsync would change, without writing or deleting.
  -h, --help     Show this help.

Environment:
  RB_DRIVE_MAX_DELETE  Max files one mirror may delete (default: 100).
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

dry_run=false
subcommand=""
public_sync=false
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    remote|public)
      [ -z "$subcommand" ] || fail "only one command allowed (got '$subcommand' and '$arg')"
      subcommand="$arg"
      ;;
    *) fail "unknown argument: $arg" ;;
  esac
done

[ -n "$subcommand" ] || { usage >&2; exit 2; }

# A real rb-drive store always contains projects/. Without this guard an empty or
# half-built source (e.g. a freshly re-created symlink before data syncs back) would
# make rsync --delete wipe the entire destination backup.
[ -d "${repo_root}/rb-drive/projects" ] \
  || fail "rb-drive/projects not found — refusing to mirror a missing or empty source with --delete"

# --delete mirrors the source exactly; --max-delete is the runaway-deletion
# backstop to the sentinel above. Subcommands choose their own symlink behavior.
# The array stays non-empty so "${rsync_opts[@]}" is safe under set -u on bash 3.2.
rsync_opts=(-av --delete "--max-delete=${max_delete}")
if [ "$dry_run" = true ]; then
  rsync_opts+=(--dry-run)
fi

# Patterns withheld from the PUBLIC share only: VCS internals plus credential-shaped
# files, so a stray secret in rb-drive can never ride along to a public Drive folder.
# This withholds only secrets, never documents — content is shared deliberately.
public_excludes=(
  --exclude='.git' --exclude='.jj'
  --exclude='.env*' --exclude='.netrc'
  --exclude='*.pem' --exclude='*.key' --exclude='*.p12' --exclude='*.pfx'
  --exclude='id_rsa*' --exclude='id_dsa*' --exclude='id_ecdsa*' --exclude='id_ed25519*'
  --exclude='*credential*' --exclude='*.keychain*'
)

case "$subcommand" in
  remote)
    # No trailing slash: rsync copies the rb-drive directory itself, so the private
    # backup nests as <dest>/rb-drive/ — a faithful, low-churn mirror of the store.
    # -L dereferences symlinks so the private Drive copy holds real files.
    rsync_opts+=(-L)
    dest="${repo_root}/.rb-drive-remote/"
    src="${repo_root}/rb-drive"
    ;;
  public)
    # Trailing slash: rsync copies the CONTENTS, so agents/ and projects/ land directly
    # at the share root (no rb-drive/ level) for easy public browsing.
    # Public sync excludes symlinks entirely: a safe-looking link name can target
    # private data that filename excludes would not catch if links are dereferenced.
    rsync_opts+=(--no-links --delete-excluded "${public_excludes[@]}")
    public_sync=true
    dest="${repo_root}/.rb-drive-public-share/"
    src="${repo_root}/rb-drive/"
    ;;
esac

# Require the destination to be a pre-created symlink (to the Drive folder); otherwise
# rsync would silently mirror into a local, gitignored dir that never reaches Drive.
[ -L "${dest%/}" ] || fail "${dest%/} is not a symlink — point it at your Drive folder before syncing"

if [ "$public_sync" = true ]; then
  while IFS= read -r -d '' symlink_path; do
    rel_path="${symlink_path#"$src"}"
    [ "$rel_path" != "$symlink_path" ] \
      || fail "internal error: symlink path escaped public source: $symlink_path"
    rsync_opts+=("--exclude=${rel_path}")
  done < <(find "$src" -type l -print0)
fi

rsync "${rsync_opts[@]}" "$src" "$dest"
