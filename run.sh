#!/usr/bin/env bash
#
# github-to-gitea-auto-migration-tool: sync a GitHub account (repos, orgs, gists, webhooks,
# deploy keys, Projects v2) into Gitea. Configuration lives in .env; see
# example.env and README.md for all options and token scopes.
#
# Usage: ./run.sh [--dry-run] [--yes]
#
# Requires: bash 3.2+, curl 7.55+, jq 1.5+; git (SYNC_EXISTING=git or
#           OVERWRITE_LFS=true); git-lfs (OVERWRITE_LFS=true).
#
# The implementation is split across lib/*.sh. Every module is `source`d into
# this shell so configuration, counters, temp files, and failure trackers are
# shared. Do not execute files under lib/ directly.

set -o pipefail

START_TIME=$(date +%s)
START_DATE=$(date "+%Y-%m-%d %H:%M:%S")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Usage: ./run.sh [--dry-run] [--yes]

  --dry-run   Read everything, change nothing on Gitea (counts = planned actions)
  --yes       Skip confirmation for destructive OVERWRITE_* flags and SYNC_EXISTING=git
              (which force-updates branches/tags and prunes refs absent from GitHub);
              OVERWRITE_LFS itself deletes nothing

  ALLOW_INSECURE_HTTP=true  Permit plain HTTP to Gitea only on a trusted isolated network
                             (default: false; HTTPS is required otherwise)

Configuration: .env next to run.sh (override: ENV_FILE=/path/to/file ./run.sh).
Required: GITHUB_USER, GITHUB_TOKEN, GITEA_URL, GITEA_USER, GITEA_TOKEN.
See example.env and README.md for all options, token scopes, and behavior.
EOF
}

DRY_RUN_FLAG=""
ASSUME_YES_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN_FLAG=true ;;
        -y|--yes)  ASSUME_YES_FLAG=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/utils.sh
. "$SCRIPT_DIR/lib/utils.sh"
# shellcheck source=lib/logging.sh
. "$SCRIPT_DIR/lib/logging.sh"
# shellcheck source=lib/http.sh
. "$SCRIPT_DIR/lib/http.sh"
# shellcheck source=lib/git_sync.sh
. "$SCRIPT_DIR/lib/git_sync.sh"
# shellcheck source=lib/webhooks.sh
. "$SCRIPT_DIR/lib/webhooks.sh"
# shellcheck source=lib/keys.sh
. "$SCRIPT_DIR/lib/keys.sh"
# shellcheck source=lib/verify.sh
. "$SCRIPT_DIR/lib/verify.sh"
# shellcheck source=lib/projects.sh
. "$SCRIPT_DIR/lib/projects.sh"
# shellcheck source=lib/repos.sh
. "$SCRIPT_DIR/lib/repos.sh"
# shellcheck source=lib/orgs.sh
. "$SCRIPT_DIR/lib/orgs.sh"
# shellcheck source=lib/gists.sh
. "$SCRIPT_DIR/lib/gists.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/summary.sh
. "$SCRIPT_DIR/lib/summary.sh"

preflight
migrate_personal_repos
migrate_orgs
migrate_all_projects
migrate_gists
print_summary
