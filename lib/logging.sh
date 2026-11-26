# Sourced by run.sh (must come AFTER lib/config.sh so tokens are validated,
# and AFTER the destructive-options prompt in config.sh, so tee does not buffer it).
#
# Sets up: log file + tee redirect, temp directory + cleanup trap, token header
# files, GIT_ASKPASS helper, and all global counters/trackers.

umask 077
LOG_FILE="${LOG_FILE:-migration-$(date +%Y-%m-%d-%H%M%S).log}"
: >> "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || { echo "Error: cannot secure log file permissions: $LOG_FILE"; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t ghmigrate)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
GH_HDR="$TMP_DIR/gh.hdr"
GITEA_HDR="$TMP_DIR/gitea.hdr"
HDRS_FILE="$TMP_DIR/resp.hdrs"
BODY_FILE="$TMP_DIR/resp.body"
ERR_FILE="$TMP_DIR/curl.err"
PAYLOAD_FILE="$TMP_DIR/payload.json"
ASKPASS="$TMP_DIR/askpass.sh"

printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\nUser-Agent: github-to-gitea-auto-migration-tool\n' "$GITHUB_TOKEN" > "$GH_HDR"
printf 'Authorization: token %s\nAccept: application/json\nContent-Type: application/json\n' "$GITEA_TOKEN" > "$GITEA_HDR"

cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) case "$1" in *github.com*) echo "$GITHUB_USER" ;; *) echo "$GITEA_USER" ;; esac ;;
  *)          case "$1" in *github.com*) echo "$GITHUB_TOKEN" ;; *) echo "$GITEA_TOKEN" ;; esac ;;
esac
EOF
chmod 700 "$ASKPASS"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0

# --- Counters & trackers ----------------------------------------------------
for c in personal_repos_scanned org_repos_scanned repos_private repos_public repos_archived \
         repos_migrated repos_synced repos_lfs_synced repos_uptodate repos_skipped repos_overwritten repos_failed \
         orgs_processed orgs_created orgs_skipped orgs_overwritten orgs_failed \
         org_webhooks_migrated org_webhooks_skipped org_webhooks_overwritten org_webhooks_failed \
         repo_webhooks_migrated repo_webhooks_skipped repo_webhooks_overwritten repo_webhooks_failed \
         keys_migrated keys_skipped keys_overwritten keys_failed \
         projects_scanned projects_migrated projects_skipped projects_overwritten projects_failed \
         project_items_added project_items_skipped project_items_missing project_items_failed \
         gists_scanned gists_public gists_secret gists_migrated gists_synced gists_uptodate \
         gists_skipped gists_overwritten gists_failed \
         verified_ok verified_mismatch verified_error wikis_enabled gh_calls; do
    printf -v "count_$c" '%d' 0
done
for k in issues prs releases labels milestones branches tags; do
    printf -v "tot_gh_$k" '%d' 0
    printf -v "tot_gitea_$k" '%d' 0
done

failed_items=()
warnings=()
item_log=()

# Dry-run bookkeeping: name of the org whose overwrite was only simulated, so
# repos.sh treats that org's repos as absent. Set per-iteration in orgs.sh.
ORG_OVERWRITE_DRYRUN_OWNER=""
