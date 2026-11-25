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

set -o pipefail

START_TIME=$(date +%s)
START_DATE=$(date "+%Y-%m-%d %H:%M:%S")

usage() {
    cat <<'EOF'
Usage: ./run.sh [--dry-run] [--yes]

  --dry-run   Read everything, change nothing on Gitea (counts = planned actions)
  --yes       Skip confirmation for destructive OVERWRITE_* flags and SYNC_EXISTING=git
              (which force-updates branches/tags and prunes refs absent from GitHub);
              OVERWRITE_LFS itself deletes nothing

  ALLOW_INSECURE_HTTP=true  Permit plain HTTP to Gitea only on a trusted isolated network
                             (default: false; HTTPS is required otherwise)

Configuration: .env in the current directory.
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

# ---------------------------------------------------------------------------
# LOAD .ENV + DEFAULTS + VALIDATION
# ---------------------------------------------------------------------------
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then
    echo "Loading configuration from $ENV_FILE ..."
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
else
    echo "Error: $ENV_FILE not found in the current directory!"
    exit 1
fi

MAKE_PRIVATE="${MAKE_PRIVATE:-true}"
ALLOW_INSECURE_HTTP="${ALLOW_INSECURE_HTTP:-false}"
MIGRATE_REPOS="${MIGRATE_REPOS:-true}"
MIGRATE_ORGS="${MIGRATE_ORGS:-true}"
MIGRATE_GISTS="${MIGRATE_GISTS:-true}"
MIGRATE_ISSUES="${MIGRATE_ISSUES:-true}"
MIGRATE_PULL_REQUESTS="${MIGRATE_PULL_REQUESTS:-true}"
MIGRATE_RELEASES="${MIGRATE_RELEASES:-true}"
MIGRATE_LABELS="${MIGRATE_LABELS:-true}"
MIGRATE_MILESTONES="${MIGRATE_MILESTONES:-true}"
MIGRATE_WIKI="${MIGRATE_WIKI:-true}"
MIGRATE_PROJECTS="${MIGRATE_PROJECTS:-true}"
MIGRATE_WEBHOOKS="${MIGRATE_WEBHOOKS:-true}"
MIGRATE_ORG_WEBHOOKS="${MIGRATE_ORG_WEBHOOKS:-true}"
MIGRATE_DEPLOY_KEYS="${MIGRATE_DEPLOY_KEYS:-true}"
MIGRATE_LFS="${MIGRATE_LFS:-true}"

OVERWRITE_REPOS="${OVERWRITE_REPOS:-false}"
OVERWRITE_ORGS="${OVERWRITE_ORGS:-false}"
OVERWRITE_GISTS="${OVERWRITE_GISTS:-false}"
OVERWRITE_PROJECTS="${OVERWRITE_PROJECTS:-false}"
OVERWRITE_WEBHOOKS="${OVERWRITE_WEBHOOKS:-false}"
OVERWRITE_ORG_WEBHOOKS="${OVERWRITE_ORG_WEBHOOKS:-false}"
OVERWRITE_DEPLOY_KEYS="${OVERWRITE_DEPLOY_KEYS:-false}"
OVERWRITE_LFS="${OVERWRITE_LFS:-false}"

PROJECTS_STATUS_FIELD="${PROJECTS_STATUS_FIELD:-Status}"
SYNC_EXISTING="${SYNC_EXISTING:-skip}"
VERIFY="${VERIFY:-true}"
VERIFY_ALL="${VERIFY_ALL:-false}"
HOOKS_CREATE_INACTIVE="${HOOKS_CREATE_INACTIVE:-true}"
GITHUB_AFFILIATION="${GITHUB_AFFILIATION:-owner}"
GH_MAX_WAIT="${GH_MAX_WAIT:-3700}"
DRY_RUN="${DRY_RUN:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
[ -n "$DRY_RUN_FLAG" ] && DRY_RUN=true
[ -n "$ASSUME_YES_FLAG" ] && ASSUME_YES=true

normalize_bool() {
    local n="$1" v
    v=$(printf '%s' "${!n}" | tr '[:upper:]' '[:lower:]')
    case "$v" in
        true|1|yes|y)  printf -v "$n" '%s' true ;;
        false|0|no|n)  printf -v "$n" '%s' false ;;
        *) echo "Error: $n must be true/false (got '${!n}')"; return 1 ;;
    esac
}

BOOL_VARS="MAKE_PRIVATE MIGRATE_REPOS MIGRATE_ORGS MIGRATE_GISTS MIGRATE_ISSUES MIGRATE_PULL_REQUESTS
MIGRATE_RELEASES MIGRATE_LABELS MIGRATE_MILESTONES MIGRATE_WIKI MIGRATE_LFS MIGRATE_WEBHOOKS
MIGRATE_ORG_WEBHOOKS MIGRATE_DEPLOY_KEYS MIGRATE_PROJECTS OVERWRITE_REPOS OVERWRITE_ORGS
OVERWRITE_GISTS OVERWRITE_WEBHOOKS OVERWRITE_ORG_WEBHOOKS OVERWRITE_DEPLOY_KEYS OVERWRITE_PROJECTS
OVERWRITE_LFS VERIFY VERIFY_ALL HOOKS_CREATE_INACTIVE DRY_RUN ASSUME_YES ALLOW_INSECURE_HTTP"
for v in $BOOL_VARS; do normalize_bool "$v" || exit 1; done

case "$SYNC_EXISTING" in skip|git) ;; *) echo "Error: SYNC_EXISTING must be 'skip' or 'git'"; exit 1 ;; esac

for v in GITHUB_USER GITHUB_TOKEN GITEA_URL GITEA_USER GITEA_TOKEN; do
    if [ -z "${!v:-}" ]; then echo "Error: $v is missing in $ENV_FILE"; exit 1; fi
done
GITEA_URL="${GITEA_URL%/}"
case "$GITEA_URL" in
    https://*) ;;
    http://*)
        if [ "$ALLOW_INSECURE_HTTP" != true ]; then
            echo "Error: GITEA_URL must use HTTPS. For a trusted isolated network only, set ALLOW_INSECURE_HTTP=true."
            exit 1
        fi
        ;;
    *) echo "Error: GITEA_URL must be an http:// or https:// URL."; exit 1 ;;
esac

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: '$tool' is required but not installed."; exit 1; }
done
if [ "$SYNC_EXISTING" = "git" ] || [ "$OVERWRITE_LFS" = true ]; then
    command -v git >/dev/null 2>&1 || { echo "Error: 'git' is required for SYNC_EXISTING=git / OVERWRITE_LFS=true."; exit 1; }
fi
if [ "$OVERWRITE_LFS" = true ]; then
    if [ "$MIGRATE_LFS" != true ]; then
        echo "Error: OVERWRITE_LFS=true requires MIGRATE_LFS=true."; exit 1
    fi
    git lfs version >/dev/null 2>&1 || { echo "Error: 'git-lfs' is required for OVERWRITE_LFS=true."; exit 1; }
fi

# Confirm destructive options BEFORE logging starts (so the prompt is not buffered by tee)
# (OVERWRITE_LFS deletes nothing, so it does not need confirmation.)
if [ "$DRY_RUN" != true ] && [ "$ASSUME_YES" != true ]; then
    if [ "$OVERWRITE_REPOS" = true ] || [ "$OVERWRITE_ORGS" = true ] || [ "$OVERWRITE_GISTS" = true ] || \
       [ "$OVERWRITE_WEBHOOKS" = true ] || [ "$OVERWRITE_ORG_WEBHOOKS" = true ] || \
       [ "$OVERWRITE_DEPLOY_KEYS" = true ] || [ "$OVERWRITE_PROJECTS" = true ] || [ "$SYNC_EXISTING" = git ]; then
        echo "WARNING: destructive operations are enabled on $GITEA_URL."
        if [ "$OVERWRITE_ORGS" = true ]; then
            echo "  OVERWRITE_ORGS deletes each target organization and all repositories currently inside it."
            echo "  The script then recreates the organization and re-imports only repos returned by GitHub"
            echo "  for this token; destination-only or source-inaccessible repos may not be recoverable."
        fi
        if [ "$OVERWRITE_REPOS" = true ] || [ "$OVERWRITE_GISTS" = true ] || \
           [ "$OVERWRITE_WEBHOOKS" = true ] || [ "$OVERWRITE_ORG_WEBHOOKS" = true ] || \
           [ "$OVERWRITE_DEPLOY_KEYS" = true ] || [ "$OVERWRITE_PROJECTS" = true ]; then
            echo "  Other OVERWRITE_* flags may delete and recreate repositories, Gists, webhooks,"
            echo "  deploy keys, and/or project boards."
        fi
        if [ "$SYNC_EXISTING" = git ]; then
            echo "  SYNC_EXISTING=git force-updates destination branches/tags to match GitHub and prunes"
            echo "  destination branch/tag refs that no longer exist on GitHub."
        fi
        echo "  Back up the destination before proceeding."
        if [ -t 0 ]; then
            read -r -p 'Type DELETE to continue: ' confirm
            [ "$confirm" = "DELETE" ] || { echo "Aborted."; exit 1; }
        else
            echo "Non-interactive shell: pass --yes (or ASSUME_YES=true) to confirm. Aborting."
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# LOGGING, TEMP FILES, CREDENTIAL FILES (tokens never appear in curl argv)
# ---------------------------------------------------------------------------
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

printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\nUser-Agent: gh2gitea-migrator\n' "$GITHUB_TOKEN" > "$GH_HDR"
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

# ---------------------------------------------------------------------------
# COUNTERS & TRACKERS
# ---------------------------------------------------------------------------
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

inc() { printf -v "$1" '%d' $(( ${!1} + ${2:-1} )); }
is_2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
record_failure() { failed_items+=("$1"); echo "     [ERROR] $1"; }
warn() { warnings+=("$1"); echo "     [WARN] $1"; }
log_item() { item_log+=("$(printf '%-10s %-7s %-48s %s' "$1" "$2" "$3" "${4:-}")"); }
onoff() { if [ "$1" = true ]; then echo ON; else echo OFF; fi; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
# HTTP LAYER (rate-limit aware, token-safe, dry-run aware)
#   http_req <gh|gitea> <METHOD> <url> [json] [timeout]
#   sets RESP_CODE, RESP_BODY, RESP_HEADERS
# ---------------------------------------------------------------------------
RESP_CODE=0; RESP_BODY=""; RESP_HEADERS=""

hdr_val() { grep -i "^$1:" "$HDRS_FILE" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}'; }
jmsg() { printf '%s' "$RESP_BODY" | jq -r 'if type=="object" then (.message // empty) else empty end' 2>/dev/null | head -c 200; }

http_req() {
    local target="$1" method="$2" url="$3" data="${4:-}" tmo="${5:-120}"
    local hdr code attempt=0 remaining reset retry wait now
    if [ "$target" = gh ]; then hdr="$GH_HDR"; else hdr="$GITEA_HDR"; fi

    if [ "$target" = gitea ] && [ "$method" != GET ] && [ "$DRY_RUN" = true ]; then
        echo "     [DRY-RUN] $method ${url#"$GITEA_URL"}"
        if [ "$method" = DELETE ]; then RESP_CODE=204; else RESP_CODE=201; fi
        RESP_BODY='{"id":0}'; RESP_HEADERS=""
        return 0
    fi

    while :; do
        attempt=$((attempt + 1))
        if [ "$target" = gh ]; then inc count_gh_calls; fi
        : > "$HDRS_FILE"; : > "$BODY_FILE"
        local -a args=(-sS -X "$method" -H "@$hdr" -D "$HDRS_FILE" -o "$BODY_FILE" -w '%{http_code}' --max-time "$tmo")
        if [ -n "$data" ]; then
            printf '%s' "$data" > "$PAYLOAD_FILE"
            args+=(--data-binary "@$PAYLOAD_FILE")
        fi
        code=$(curl "${args[@]}" "$url" 2>"$ERR_FILE")
        [ -z "$code" ] && code=000

        # transport failure: retry idempotent requests only
        if [ "$code" = 000 ] && [ "$method" = GET ] && [ "$attempt" -le 3 ]; then
            sleep $((attempt * 3)); continue
        fi

        if [ "$target" = gh ]; then
            remaining=$(hdr_val x-ratelimit-remaining)
            reset=$(hdr_val x-ratelimit-reset)
            retry=$(hdr_val retry-after)
            now=$(date +%s)
            if [ "$code" = 403 ] || [ "$code" = 429 ]; then
                wait=0
                if [ -n "$retry" ]; then wait="$retry"
                elif [ "$remaining" = "0" ] && [ -n "$reset" ]; then wait=$((reset - now + 2))
                elif grep -qi 'rate limit' "$BODY_FILE" 2>/dev/null; then wait=60
                fi
                if [ "$wait" -gt 0 ] 2>/dev/null && [ "$attempt" -le 5 ]; then
                    [ "$wait" -gt "$GH_MAX_WAIT" ] && wait="$GH_MAX_WAIT"
                    echo "     [RATE LIMIT] GitHub limit hit (HTTP $code). Sleeping ${wait}s..."
                    sleep "$wait"; continue
                fi
            elif [ -n "$remaining" ] && [ -n "$reset" ] && [ "$remaining" -le 2 ] 2>/dev/null; then
                wait=$((reset - now + 2))
                if [ "$wait" -gt 0 ]; then
                    [ "$wait" -gt "$GH_MAX_WAIT" ] && wait="$GH_MAX_WAIT"
                    echo "     [RATE LIMIT] GitHub quota nearly exhausted. Sleeping ${wait}s..."
                    sleep "$wait"
                fi
            fi
        fi
        break
    done

    RESP_CODE="$code"
    RESP_BODY=$(cat "$BODY_FILE")
    RESP_HEADERS=$(cat "$HDRS_FILE")
    if [ "$code" = 000 ]; then RESP_BODY="{\"message\":\"transport error: $(head -c 150 "$ERR_FILE" | tr '"\n' "' ")\"}"; fi
    return 0
}

# paginate <gh|gitea> <url>  -> PAGED_JSON (merged array), PAGED_CODE, PAGED_ERR ; returns 1 on error
PAGED_JSON='[]'; PAGED_CODE=0; PAGED_ERR=""
paginate() {
    local target="$1" url="$2" page=1 size param sep n
    if [ "$target" = gh ]; then size=100; param=per_page; else size=50; param=limit; fi
    case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
    PAGED_JSON='[]'; PAGED_ERR=""; PAGED_CODE=0
    while [ "$page" -le 500 ]; do
        http_req "$target" GET "${url}${sep}${param}=${size}&page=${page}"
        if ! is_2xx "$RESP_CODE"; then
            PAGED_CODE="$RESP_CODE"; PAGED_ERR="HTTP $RESP_CODE $(jmsg)"; return 1
        fi
        if ! printf '%s' "$RESP_BODY" | jq -e 'type=="array"' >/dev/null 2>&1; then
            PAGED_CODE="$RESP_CODE"; PAGED_ERR="unexpected (non-array) response"; return 1
        fi
        n=$(printf '%s' "$RESP_BODY" | jq 'length')
        [ "$n" -eq 0 ] && break
        PAGED_JSON=$(printf '%s\n%s' "$PAGED_JSON" "$RESP_BODY" | jq -c -s 'add')
        # GitHub's requested per_page=100 is the documented upper bound for the
        # endpoints used here, so a short page ends pagination. Gitea can clamp
        # limit=50 to its configured api.MAX_RESPONSE_ITEMS; a short Gitea page
        # is therefore NOT proof that it was the last page. Keep paging until
        # Gitea returns an empty array.
        if [ "$target" = gh ] && [ "$n" -lt "$size" ]; then break; fi
        page=$((page + 1))
    done
    if [ "$page" -gt 500 ]; then
        PAGED_CODE=0; PAGED_ERR="pagination exceeded the 500-page safety limit (results may be incomplete)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# GIT SYNC (branches/tags + LFS)
#   git_sync <src> <dst> <do_refs true|false> <lfs_mode off|auto|force>
#     do_refs  : compare refs and push branches + tags (with prune)
#     lfs_mode : off   = never touch LFS
#                auto  = push LFS objects only when refs changed
#                force = always fetch ALL LFS objects from GitHub and push them
#                        to Gitea (OVERWRITE_LFS); failures are errors
#   returns 0 = did something, 2 = nothing to do (already up to date), 1 = failed
#   sets GIT_ERR and GIT_LFS_DONE (true when LFS objects were (or would be) pushed)
# ---------------------------------------------------------------------------
GIT_ERR=""; GIT_LFS_DONE=false
G() { git -c credential.helper= "$@"; }
git_refs() { G ls-remote --heads --tags "$1" </dev/null 2>/dev/null | sort; }

git_sync() {
    local src="$1" dst="$2" do_refs="${3:-true}" lfs_mode="${4:-off}"
    local a b tmp same=false lfs_run=false
    GIT_ERR=""; GIT_LFS_DONE=false

    if [ "$do_refs" = true ]; then
        a=$(git_refs "$src") || { GIT_ERR="ls-remote failed on GitHub"; return 1; }
        b=$(git_refs "$dst") || { GIT_ERR="ls-remote failed on Gitea"; return 1; }
        [ "$a" = "$b" ] && same=true
    else
        same=true
    fi

    case "$lfs_mode" in
        force) lfs_run=true ;;
        auto)  [ "$same" != true ] && lfs_run=true ;;
    esac

    if [ "$same" = true ] && [ "$lfs_run" != true ]; then return 2; fi

    if [ "$DRY_RUN" = true ]; then
        [ "$same" != true ] && echo "     [DRY-RUN] would git-sync $dst"
        [ "$lfs_run" = true ] && echo "     [DRY-RUN] would re-push all LFS objects to $dst"
        GIT_LFS_DONE=$lfs_run
        return 0
    fi

    tmp=$(mktemp -d "$TMP_DIR/sync.XXXXXX")
    if ! G clone --mirror --quiet "$src" "$tmp/r" </dev/null 2>"$tmp/err"; then
        GIT_ERR="clone failed: $(head -c 200 "$tmp/err" | tr '\n' ' ')"; rm -rf "$tmp"; return 1
    fi
    if [ "$same" != true ]; then
        if ! G -C "$tmp/r" push --prune --quiet "$dst" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' </dev/null 2>"$tmp/err"; then
            GIT_ERR="push failed: $(head -c 200 "$tmp/err" | tr '\n' ' ')"; rm -rf "$tmp"; return 1
        fi
    fi
    if [ "$lfs_run" = true ]; then
        if ! G lfs version >/dev/null 2>&1; then
            if [ "$lfs_mode" = force ]; then
                GIT_ERR="git-lfs is not installed"; rm -rf "$tmp"; return 1
            fi
            warn "git-lfs not installed: LFS objects of $dst were not pushed"
        elif G -C "$tmp/r" lfs fetch --all origin </dev/null >"$tmp/lfs.out" 2>&1 && \
             G -C "$tmp/r" lfs push --all "$dst" </dev/null >>"$tmp/lfs.out" 2>&1; then
            GIT_LFS_DONE=true
        elif [ "$lfs_mode" = force ]; then
            GIT_ERR="LFS sync failed: $(tail -c 200 "$tmp/lfs.out" | tr '\n' ' ')"; rm -rf "$tmp"; return 1
        else
            warn "LFS sync skipped/failed for $dst (repo may not use LFS)"
        fi
    fi
    rm -rf "$tmp"
    return 0
}

# ---------------------------------------------------------------------------
# WEBHOOKS (repo + org) and DEPLOY KEYS
# ---------------------------------------------------------------------------
EVENT_MAP_JQ='
def m: {
  "push":["push"],"create":["create"],"delete":["delete"],"fork":["fork"],
  "issues":["issues","issue_assign","issue_label","issue_milestone"],
  "issue_comment":["issue_comment"],
  "pull_request":["pull_request","pull_request_assign","pull_request_label","pull_request_milestone","pull_request_sync"],
  "pull_request_review":["pull_request_review_approved","pull_request_review_rejected"],
  "pull_request_review_comment":["pull_request_review_comment"],
  "gollum":["wiki"],"repository":["repository"],"release":["release"]
};
(.events // ["push"]) as $e
| (if ($e | index("*")) != null then ([(m)[]] | add | unique)
   else ([ $e[] | ((m)[.] // []) ] | add // []) | unique end)
| if length == 0 then ["push"] else . end'

# migrate_hooks <repo|org> <github hooks url> <gitea hooks url> <label> <overwrite true|false>
migrate_hooks() {
    local scope="$1" gh_url="$2" gitea_url="$3" label="$4" overwrite="$5"
    local gh_hooks gitea_hooks hook hook_url hook_ct hook_active hook_events exists payload

    if ! paginate gh "$gh_url"; then
        if [ "$PAGED_CODE" = 403 ] || [ "$PAGED_CODE" = 404 ]; then
            warn "Webhooks of $label not readable (HTTP $PAGED_CODE): token lacks hook-admin permission; skipped."
        else
            inc "count_${scope}_webhooks_failed"; record_failure "Webhook List ($scope): $label ($PAGED_ERR)"
        fi
        return
    fi
    gh_hooks="$PAGED_JSON"
    [ "$(printf '%s' "$gh_hooks" | jq 'length')" -eq 0 ] && return

    if ! paginate gitea "$gitea_url"; then
        if [ "$DRY_RUN" = true ]; then PAGED_JSON='[]'
        else inc "count_${scope}_webhooks_failed"; record_failure "Webhook List on Gitea ($scope): $label ($PAGED_ERR)"; return
        fi
    fi
    gitea_hooks="$PAGED_JSON"

    while IFS= read -r hook; do
        hook_url=$(printf '%s' "$hook" | jq -r '.config.url // empty')
        [ -z "$hook_url" ] && continue
        hook_ct=$(printf '%s' "$hook" | jq -r '.config.content_type // "json"')
        hook_active=$(printf '%s' "$hook" | jq -r 'if .active == null then true else .active end')
        [ "$HOOKS_CREATE_INACTIVE" = true ] && hook_active=false
        hook_unknown=$(printf '%s' "$hook" | jq -r '
            def m: {"push":1,"create":1,"delete":1,"fork":1,"issues":1,"issue_comment":1,"pull_request":1,"pull_request_review":1,"pull_request_review_comment":1,"gollum":1,"repository":1,"release":1};
            (.events // ["push"]) as $e
            | if ($e | index("*")) != null then ""
              else [$e[] | select((m[.] // null) == null)] | unique | join(", ") end')
        if [ -n "$hook_unknown" ]; then
            warn "Webhook $label -> $hook_url uses unsupported GitHub event(s): $hook_unknown; skipped rather than mapped incorrectly."
            inc "count_${scope}_webhooks_skipped"
            continue
        fi
        hook_events=$(printf '%s' "$hook" | jq -c "$EVENT_MAP_JQ")

        exists=$(printf '%s' "$gitea_hooks" | jq -r --arg u "$hook_url" '[.[]? | select(.config.url == $u) | .id] | first // empty')

        if [ -n "$exists" ] && [ "$overwrite" = true ]; then
            echo "     [WEBHOOK] Overwrite enabled. Deleting existing webhook -> $hook_url"
            http_req gitea DELETE "$gitea_url/$exists"
            if is_2xx "$RESP_CODE"; then inc "count_${scope}_webhooks_overwritten"; exists=""
            else inc "count_${scope}_webhooks_failed"; record_failure "Webhook Delete ($scope): $label -> $hook_url (HTTP $RESP_CODE)"; continue
            fi
        fi

        if [ -z "$exists" ]; then
            echo "     [WEBHOOK] Migrating webhook -> $hook_url (active=$hook_active)"
            payload=$(jq -n --arg url "$hook_url" --arg ct "$hook_ct" --argjson active "$hook_active" --argjson events "$hook_events" \
                '{type:"gitea", active:$active, events:$events, config:{url:$url, content_type:$ct}}')
            http_req gitea POST "$gitea_url" "$payload"
            if is_2xx "$RESP_CODE"; then inc "count_${scope}_webhooks_migrated"
            else inc "count_${scope}_webhooks_failed"; record_failure "Webhook Create ($scope): $label -> $hook_url (HTTP $RESP_CODE $(jmsg))"
            fi
        else
            inc "count_${scope}_webhooks_skipped"
        fi
    done < <(printf '%s\n' "$gh_hooks" | jq -c '.[]')
}

# migrate_keys <github keys url> <gitea keys url> <label>
migrate_keys() {
    local gh_url="$1" gitea_url="$2" label="$3"
    local gh_keys gitea_keys key_obj key_title key_pub key_norm key_ro exists payload

    if ! paginate gh "$gh_url"; then
        if [ "$PAGED_CODE" = 403 ] || [ "$PAGED_CODE" = 404 ]; then
            warn "Deploy keys of $label not readable (HTTP $PAGED_CODE); skipped."
        else
            inc count_keys_failed; record_failure "Deploy Key List: $label ($PAGED_ERR)"
        fi
        return
    fi
    gh_keys="$PAGED_JSON"
    [ "$(printf '%s' "$gh_keys" | jq 'length')" -eq 0 ] && return

    if ! paginate gitea "$gitea_url"; then
        if [ "$DRY_RUN" = true ]; then PAGED_JSON='[]'
        else inc count_keys_failed; record_failure "Deploy Key List on Gitea: $label ($PAGED_ERR)"; return
        fi
    fi
    gitea_keys="$PAGED_JSON"

    while IFS= read -r key_obj; do
        key_title=$(printf '%s' "$key_obj" | jq -r '.title')
        key_pub=$(printf '%s' "$key_obj" | jq -r '.key')
        key_norm=$(printf '%s' "$key_pub" | awk '{print $1" "$2}')
        key_ro=$(printf '%s' "$key_obj" | jq -r 'if .read_only == null then true else .read_only end')

        exists=$(printf '%s' "$gitea_keys" | jq -r --arg k "$key_norm" \
            '[.[]? | select(((.key // "") | split(" ") | .[0:2] | join(" ")) == $k) | .id] | first // empty')

        if [ -n "$exists" ] && [ "$OVERWRITE_DEPLOY_KEYS" = true ]; then
            echo "     [DEPLOY KEY] Overwrite enabled. Deleting existing key: $key_title"
            http_req gitea DELETE "$gitea_url/$exists"
            if is_2xx "$RESP_CODE"; then inc count_keys_overwritten; exists=""
            else inc count_keys_failed; record_failure "Deploy Key Delete: $label -> $key_title (HTTP $RESP_CODE)"; continue
            fi
        fi

        if [ -z "$exists" ]; then
            echo "     [DEPLOY KEY] Migrating key: $key_title (read_only=$key_ro)"
            payload=$(jq -n --arg t "$key_title" --arg k "$key_pub" --argjson ro "$key_ro" '{title:$t, key:$k, read_only:$ro}')
            http_req gitea POST "$gitea_url" "$payload"
            if is_2xx "$RESP_CODE"; then inc count_keys_migrated
            else inc count_keys_failed; record_failure "Deploy Key Create: $label -> $key_title (HTTP $RESP_CODE $(jmsg))"
            fi
        else
            inc count_keys_skipped
        fi
    done < <(printf '%s\n' "$gh_keys" | jq -c '.[]')
}

migrate_repo_extras() {
    local gh_full="$1" label="$2"
    if [ "$MIGRATE_WEBHOOKS" = true ]; then
        migrate_hooks repo "https://api.github.com/repos/$gh_full/hooks" "$GITEA_URL/api/v1/repos/$label/hooks" "$label" "$OVERWRITE_WEBHOOKS"
    fi
    if [ "$MIGRATE_DEPLOY_KEYS" = true ]; then
        migrate_keys "https://api.github.com/repos/$gh_full/keys" "$GITEA_URL/api/v1/repos/$label/keys" "$label"
    fi
}

# ---------------------------------------------------------------------------
# PROJECTS: GitHub Projects (v2, GraphQL) -> Gitea project boards (REST, Gitea 28+)
#
#   * user-level GitHub projects  -> /api/v1/user/projects         (token owner)
#   * org-level  GitHub projects  -> /api/v1/orgs/{org}/projects
#   * options of the PROJECTS_STATUS_FIELD single-select field become columns
#     (in board order); items without a status go to a "No Status" column
#   * Issue / PR items are placed in their column. Draft items, redacted items and
#     items whose repo belongs to a different owner than the project cannot be
#     represented in Gitea and are counted as skipped.
#   * Existing Gitea projects are matched by title (skipped, or deleted and
#     recreated with OVERWRITE_PROJECTS=true).
#   * Classic (pre-v2) projects are not migrated: GitHub sunset them.
# ---------------------------------------------------------------------------
NOSTATUS_COL="No Status"
PROJECTS_GITEA=no
GITEA_PROJECTS='[]'
ORG_OVERWRITE_DRYRUN_OWNER=""

PROJ_LIST_Q='query($login:String!,$cursor:String){ OWNER(login:$login){ projectsV2(first:50, after:$cursor){ nodes{ id number title shortDescription readme closed } pageInfo{ hasNextPage endCursor } } } }'
PROJ_FIELD_Q='query($id:ID!,$f:String!){ node(id:$id){ ... on ProjectV2 { field(name:$f){ ... on ProjectV2SingleSelectField { options{ id name color } } } } } }'
PROJ_ITEMS_Q='query($id:ID!,$f:String!,$cursor:String){ node(id:$id){ ... on ProjectV2 { items(first:100, after:$cursor){ nodes{ fieldValueByName(name:$f){ ... on ProjectV2ItemFieldSingleSelectValue{ name } } content{ __typename ... on Issue{ number repository{ nameWithOwner } } ... on PullRequest{ number repository{ nameWithOwner } } } } pageInfo{ hasNextPage endCursor } } } } }'
COLOR_JQ='def hex($c): ({"GRAY":"#6e7781","BLUE":"#0969da","GREEN":"#1a7f37","YELLOW":"#9a6700","ORANGE":"#bc4c00","RED":"#cf222e","PINK":"#bf3989","PURPLE":"#8250df"}[$c] // "#6e7781"); {title:$t, color:hex($c)}'

# gql <query> [variables-json]  -> RESP_BODY ; returns 1 (GQL_ERR set) on HTTP or GraphQL errors
GQL_ERR=""
gql() {
    local q="$1" vars="${2:-}" payload
    [ -z "$vars" ] && vars='{}'
    GQL_ERR=""
    payload=$(jq -n --arg q "$q" --argjson v "$vars" '{query:$q, variables:$v}')
    http_req gh POST "https://api.github.com/graphql" "$payload"
    if ! is_2xx "$RESP_CODE"; then GQL_ERR="HTTP $RESP_CODE $(jmsg)"; return 1; fi
    if ! printf '%s' "$RESP_BODY" | jq -e 'type=="object"' >/dev/null 2>&1; then
        GQL_ERR="unexpected (non-JSON) GraphQL response"; return 1
    fi
    GQL_ERR=$(printf '%s' "$RESP_BODY" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null)
    [ -z "$GQL_ERR" ]
}

# gql_collect <query> <vars-json> <jq path to a connection>  -> GQL_NODES (merged array)
GQL_NODES='[]'
gql_collect() {
    local query="$1" vars="$2" path="$3" cursor="" next_cursor v page=0 nodes more
    GQL_NODES='[]'
    while [ "$page" -lt 500 ]; do
        page=$((page + 1))
        v=$(jq -nc --argjson base "$vars" --arg c "$cursor" '$base + (if $c == "" then {} else {cursor:$c} end)')
        gql "$query" "$v" || return 1
        if ! printf '%s' "$RESP_BODY" | jq -e \
            "($path) as \$c | (\$c | type == \"object\") and (\$c.nodes | type == \"array\") and \
             (\$c.pageInfo | type == \"object\") and (\$c.pageInfo.hasNextPage | type == \"boolean\")" \
             >/dev/null 2>&1; then
            GQL_ERR="GraphQL response did not contain a valid paginated connection"
            return 1
        fi
        nodes=$(printf '%s' "$RESP_BODY" | jq -c "($path.nodes)")
        GQL_NODES=$(printf '%s\n%s' "$GQL_NODES" "$nodes" | jq -c -s 'add')
        more=$(printf '%s' "$RESP_BODY" | jq -r "($path.pageInfo.hasNextPage)")
        [ "$more" = true ] || break
        next_cursor=$(printf '%s' "$RESP_BODY" | jq -r "($path.pageInfo.endCursor // empty)")
        if [ -z "$next_cursor" ]; then GQL_ERR="GraphQL reported another page but returned no cursor"; return 1; fi
        if [ "$next_cursor" = "$cursor" ]; then GQL_ERR="GraphQL pagination returned the same cursor twice"; return 1; fi
        cursor="$next_cursor"
        if [ "$page" -ge 500 ]; then GQL_ERR="GraphQL pagination exceeded the 500-page safety limit"; return 1; fi
    done
    return 0
}

# GitHub owner -> Gitea owner (personal repos live under GITEA_USER, orgs keep their name)
gitea_owner_for() {
    if [ "$(lc "$1")" = "$(lc "$GITHUB_USER")" ]; then printf '%s' "$GITEA_USER"; else printf '%s' "$1"; fi
}

# migrate_one_project <user|org> <github owner> <project json> <gitea projects base url> <gitea owner>
migrate_one_project() {
    local scope="$1" owner="$2" proj="$3" base="$4" gitea_owner="$5"
    local p_id p_num p_title p_desc p_closed label eid pid payload
    local p_items p_opts nostatus cols col cname ccolor cid colmap first_col ncols=0 proj_err=0
    local item ctype crepo cnum cstatus tgt_owner tgt_name target_col issue_id
    local title_ids owned_ids source_marker description_payload
    local total=0 added=0 skipped=0 missing=0 failed=0

    p_id=$(printf '%s' "$proj" | jq -r '.id')
    p_num=$(printf '%s' "$proj" | jq -r '.number')
    p_title=$(printf '%s' "$proj" | jq -r '.title')
    p_desc=$(printf '%s' "$proj" | jq -r '(.shortDescription // "") as $s | if $s != "" then $s else (.readme // "") end')
    p_closed=$(printf '%s' "$proj" | jq -r '.closed // false')
    label="$scope:$owner #$p_num $p_title"
    inc count_projects_scanned
    echo "  -> Checking project: $label..."

    # --- match only boards carrying this source project's marker ------------
    # A title alone is not proof of ownership; never delete an unrelated board.
    source_marker="<!-- github-project-id:$p_id -->"
    title_ids=$(printf '%s' "$GITEA_PROJECTS" | jq -r --arg t "$p_title" '[.[]? | select(.title == $t) | .id] | .[]')
    owned_ids=$(printf '%s' "$GITEA_PROJECTS" | jq -r --arg m "$source_marker" '[.[]? | select((.description // "") | contains($m)) | .id] | .[]')
    if [ -n "$owned_ids" ]; then
        if [ "$OVERWRITE_PROJECTS" = true ]; then
            echo "     [OVERWRITE PROJECT] Deleting previously migrated board(s) matching source ID..."
            while IFS= read -r eid; do
                [ -z "$eid" ] && continue
                http_req gitea DELETE "$base/$eid"
                if ! is_2xx "$RESP_CODE" && [ "$RESP_CODE" != 404 ]; then
                    inc count_projects_failed
                    record_failure "Project Delete: $label (HTTP $RESP_CODE $(jmsg))"
                    log_item FAILED project "$label" "delete failed"; return
                fi
            done <<< "$owned_ids"
            inc count_projects_overwritten
            GITEA_PROJECTS=$(printf '%s' "$GITEA_PROJECTS" | jq -c --arg m "$source_marker" '[.[]? | select(((.description // "") | contains($m)) | not)]')
        else
            echo "     [SKIP] This GitHub project already has a marked Gitea board."
            inc count_projects_skipped; log_item SKIPPED project "$label" "already exists"; return
        fi
    elif [ -n "$title_ids" ]; then
        warn "Project '$p_title' already exists on Gitea without this script's source marker; it was not overwritten."
        inc count_projects_skipped; log_item SKIPPED project "$label" "same title; ownership unverified"; return
    fi

    # --- read board definition + items from GitHub -------------------------
    if ! gql_collect "$PROJ_ITEMS_Q" "$(jq -nc --arg id "$p_id" --arg f "$PROJECTS_STATUS_FIELD" '{id:$id, f:$f}')" '.data.node.items'; then
        inc count_projects_failed
        record_failure "Project Items Read: $label ($GQL_ERR)"
        log_item FAILED project "$label" "reading items failed"; return
    fi
    p_items="$GQL_NODES"

    p_opts='[]'
    if gql "$PROJ_FIELD_Q" "$(jq -nc --arg id "$p_id" --arg f "$PROJECTS_STATUS_FIELD" '{id:$id, f:$f}')"; then
        p_opts=$(printf '%s' "$RESP_BODY" | jq -c '[.data.node.field.options[]? | {name, color}]')
    else
        warn "Project $label: could not read field '$PROJECTS_STATUS_FIELD' ($GQL_ERR); all items go to '$NOSTATUS_COL'."
    fi

    nostatus=$(printf '%s' "$p_items" | jq --argjson o "$p_opts" \
        '[.[] | select(((.fieldValueByName.name // "") as $s | $s == "" or (($o | map(.name) | index($s)) == null)))] | length')
    cols=$(jq -nc --argjson o "$p_opts" --argjson n "$nostatus" --arg ns "$NOSTATUS_COL" \
        '(if $n > 0 then [{name:$ns, color:"GRAY"}] else [] end) + $o')

    # --- create the project ------------------------------------------------
    echo "     [MIGRATE] Creating project board on Gitea..."
    if [ -n "$p_desc" ]; then
        description_payload=$(printf '%s\n\n%s' "$p_desc" "$source_marker")
    else
        description_payload="$source_marker"
    fi
    payload=$(jq -n --arg t "$p_title" --arg d "$description_payload" '{title:$t, description:$d}')
    http_req gitea POST "$base" "$payload"
    if ! is_2xx "$RESP_CODE"; then
        inc count_projects_failed
        record_failure "Project Create: $label (HTTP $RESP_CODE $(jmsg))"
        log_item FAILED project "$label" "creation failed"; return
    fi
    pid=$(printf '%s' "$RESP_BODY" | jq -r '.id // empty')
    if [ -z "$pid" ]; then
        inc count_projects_failed
        record_failure "Project Create: $label (response contained no project id)"
        log_item FAILED project "$label" "no id returned"; return
    fi

    # --- columns -----------------------------------------------------------
    colmap='{}'; first_col=""
    while IFS= read -r col; do
        [ -z "$col" ] && continue
        cname=$(printf '%s' "$col" | jq -r '.name')
        ccolor=$(printf '%s' "$col" | jq -r '.color // "GRAY"')
        payload=$(jq -n --arg t "$cname" --arg c "$ccolor" "$COLOR_JQ")
        http_req gitea POST "$base/$pid/columns" "$payload"
        if is_2xx "$RESP_CODE"; then
            cid=$(printf '%s' "$RESP_BODY" | jq -r '.id // empty')
            if [ -z "$cid" ]; then
                proj_err=1
                record_failure "Project Column Create: $label -> $cname (response contained no column id)"
            else
                colmap=$(printf '%s' "$colmap" | jq -c --arg n "$cname" --arg i "$cid" '. + {($n):$i}')
                [ -z "$first_col" ] && first_col="$cid"
                ncols=$((ncols + 1))
            fi
        else
            proj_err=1
            record_failure "Project Column Create: $label -> $cname (HTTP $RESP_CODE $(jmsg))"
        fi
    done < <(printf '%s' "$cols" | jq -c '.[]')

    if [ -n "$first_col" ]; then
        http_req gitea POST "$base/$pid/columns/$first_col/default"
        if ! is_2xx "$RESP_CODE"; then
            # The board and its columns can still be usable; do not delete a
            # successfully populated board because this preference failed.
            warn "Project $label: could not set the default column (HTTP $RESP_CODE $(jmsg)); board retained."
        fi
    fi

    # --- items -------------------------------------------------------------
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        total=$((total + 1))
        ctype=$(printf '%s' "$item" | jq -r '.content.__typename // ""')
        crepo=$(printf '%s' "$item" | jq -r '.content.repository.nameWithOwner // ""')
        cnum=$(printf '%s' "$item" | jq -r '.content.number // 0')
        cstatus=$(printf '%s' "$item" | jq -r '.fieldValueByName.name // ""')

        case "$ctype" in
            Issue|PullRequest) ;;
            *) skipped=$((skipped + 1)); inc count_project_items_skipped; continue ;;   # draft / redacted
        esac

        tgt_owner=$(gitea_owner_for "${crepo%%/*}")
        tgt_name="${crepo#*/}"
        if [ "$(lc "$tgt_owner")" != "$(lc "$gitea_owner")" ]; then
            skipped=$((skipped + 1)); inc count_project_items_skipped      # other owner's repo
            continue
        fi

        target_col=$(printf '%s' "$colmap" | jq -r --arg s "$cstatus" --arg ns "$NOSTATUS_COL" '(.[$s] // .[$ns]) // empty')
        if [ -z "$target_col" ]; then
            failed=$((failed + 1)); inc count_project_items_failed; continue
        fi

        if [ "$DRY_RUN" = true ]; then
            added=$((added + 1)); inc count_project_items_added; continue
        fi

        # Gitea wants the GLOBAL issue id (PRs are issues too), not the repo-local number
        http_req gitea GET "$GITEA_URL/api/v1/repos/$tgt_owner/$tgt_name/issues/$cnum"
        if [ "$RESP_CODE" = 404 ]; then
            missing=$((missing + 1)); inc count_project_items_missing
            echo "     [SKIP] $crepo#$cnum not found on Gitea (not migrated?)"
            continue
        fi
        if ! is_2xx "$RESP_CODE"; then
            failed=$((failed + 1)); inc count_project_items_failed
            echo "     [ERROR] lookup of $crepo#$cnum failed (HTTP $RESP_CODE)"
            continue
        fi
        issue_id=$(printf '%s' "$RESP_BODY" | jq -r '.id // empty')
        if [ -z "$issue_id" ]; then
            failed=$((failed + 1)); inc count_project_items_failed; continue
        fi

        http_req gitea POST "$base/$pid/columns/$target_col/issues/$issue_id"
        if is_2xx "$RESP_CODE"; then
            added=$((added + 1)); inc count_project_items_added
        else
            failed=$((failed + 1)); inc count_project_items_failed
            echo "     [ERROR] could not add $crepo#$cnum to column (HTTP $RESP_CODE $(jmsg))"
        fi
    done < <(printf '%s' "$p_items" | jq -c '.[]')

    # --- closed projects are closed last (closed boards are read-only) -----
    if [ "$p_closed" = true ]; then
        http_req gitea PATCH "$base/$pid" '{"is_closed":true}'
        if ! is_2xx "$RESP_CODE"; then
            # Closing is a final state change, not a reason to destroy migrated
            # columns/items. Keep the board and surface the remaining mismatch.
            warn "Project $label: could not close it on Gitea (HTTP $RESP_CODE $(jmsg)); board retained open."
        fi
    fi

    if [ "$failed" -gt 0 ]; then
        proj_err=1
        record_failure "Project Items: $label ($failed item(s) could not be placed)"
    fi
    if [ "$proj_err" -eq 1 ]; then
        # Only structural/placement failures reach this branch (column creation,
        # missing column IDs, or failed item placements). Cosmetic final-state
        # failures such as setting the default/closed flag are warnings above.
        # Remove the incomplete board so the next run can retry cleanly.
        if [ "$DRY_RUN" != true ]; then
            http_req gitea DELETE "$base/$pid"
            if is_2xx "$RESP_CODE" || [ "$RESP_CODE" = 404 ]; then
                warn "Removed incomplete project board for $label so a later run can retry."
            else
                warn "Could not roll back incomplete project board for $label (HTTP $RESP_CODE $(jmsg))."
            fi
        fi
        inc count_projects_failed
        log_item FAILED project "$label" "cols=$ncols items=$added/$total skipped=$skipped missing=$missing failed=$failed"
    else
        inc count_projects_migrated
        log_item MIGRATED project "$label" "cols=$ncols items=$added/$total skipped=$skipped missing=$missing"
    fi
}

# migrate_projects_for_owner <user|org> <github login>
migrate_projects_for_owner() {
    local scope="$1" owner="$2" kind base gitea_owner q projects proj
    if [ "$scope" = user ]; then
        kind=user; base="$GITEA_URL/api/v1/user/projects"; gitea_owner="$GITEA_USER"
    else
        kind=organization; base="$GITEA_URL/api/v1/orgs/$owner/projects"; gitea_owner="$owner"
    fi
    q="${PROJ_LIST_Q/OWNER/$kind}"

    echo "Fetching GitHub Projects (v2) for $scope $owner..."
    if ! gql_collect "$q" "$(jq -nc --arg l "$owner" '{login:$l}')" ".data.$kind.projectsV2"; then
        warn "Projects of $scope $owner not readable ($GQL_ERR); skipped. Check that the token can read Projects v2 (classic PAT: read:project)."
        return
    fi
    projects="$GQL_NODES"
    if [ "$(printf '%s' "$projects" | jq 'length')" -eq 0 ]; then
        echo "     (no Projects v2 found)"; return
    fi

    # existing Gitea projects (open + closed) for title matching
    if paginate gitea "$base?state=all" || paginate gitea "$base"; then
        GITEA_PROJECTS="$PAGED_JSON"
    elif [ "$DRY_RUN" = true ]; then
        GITEA_PROJECTS='[]'
    else
        inc count_projects_failed
        record_failure "Project List on Gitea: $scope:$owner ($PAGED_ERR)"
        return
    fi

    while IFS= read -r proj; do
        migrate_one_project "$scope" "$owner" "$proj" "$base" "$gitea_owner"
    done < <(printf '%s\n' "$projects" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
# VERIFICATION: GitHub (GraphQL, 1 call) vs Gitea (X-Total-Count headers)
# ---------------------------------------------------------------------------
GQL_QUERY='query($o:String!,$n:String!){repository(owner:$o,name:$n){issues{totalCount} pullRequests{totalCount} releases{totalCount} labels{totalCount} milestones{totalCount} branches:refs(refPrefix:"refs/heads/"){totalCount} tags:refs(refPrefix:"refs/tags/"){totalCount}}}'

GITEA_TOTAL="?"
gitea_total() {
    GITEA_TOTAL="?"
    http_req gitea GET "$GITEA_URL/api/v1/$1"
    is_2xx "$RESP_CODE" || return 1
    local t
    t=$(printf '%s\n' "$RESP_HEADERS" | grep -i '^x-total-count:' | tail -1 | tr -d '\r' | awk '{print $2}')
    [ -z "$t" ] && return 1
    GITEA_TOTAL="$t"
}

VERIFY_DETAIL=""; VERIFY_MISMATCH=""
cmp_count() {
    local key="$1" ghv="$2" path="$3" flag="$4" gv
    if [ "$flag" != true ]; then VERIFY_DETAIL="$VERIFY_DETAIL$key=n/a "; return; fi
    if gitea_total "$path"; then gv="$GITEA_TOTAL"; else gv="?"; fi
    VERIFY_DETAIL="$VERIFY_DETAIL$key=$ghv/$gv "
    if [ "$gv" = "?" ]; then VERIFY_MISMATCH="$VERIFY_MISMATCH$key(unreadable) "
    else
        [ "$gv" != "$ghv" ] && VERIFY_MISMATCH="$VERIFY_MISMATCH$key(gh=$ghv,gitea=$gv) "
        inc "tot_gh_$key" "$ghv"; inc "tot_gitea_$key" "$gv"
    fi
}

# verify_repo <gh owner> <gh name> <gitea label> ; sets VERIFY_DETAIL / VERIFY_MISMATCH
verify_repo() {
    local o="$1" n="$2" label="$3" payload g_issues g_prs g_rel g_lab g_mil g_br g_tag
    VERIFY_DETAIL=""; VERIFY_MISMATCH=""
    payload=$(jq -n --arg q "$GQL_QUERY" --arg o "$o" --arg n "$n" '{query:$q, variables:{o:$o, n:$n}}')
    http_req gh POST "https://api.github.com/graphql" "$payload"
    if ! is_2xx "$RESP_CODE" || ! printf '%s' "$RESP_BODY" | jq -e '.data.repository != null' >/dev/null 2>&1; then
        inc count_verified_error; VERIFY_DETAIL="verification unavailable"
        warn "Verification could not read GitHub counts for $label"
        record_failure "Verification unavailable: $label (GitHub counts could not be read)"
        return 1
    fi
    read -r g_issues g_prs g_rel g_lab g_mil g_br g_tag < <(printf '%s' "$RESP_BODY" | jq -r \
        '.data.repository | [.issues.totalCount, .pullRequests.totalCount, .releases.totalCount, .labels.totalCount, .milestones.totalCount, .branches.totalCount, .tags.totalCount] | @tsv')

    local base="repos/$label"
    cmp_count issues     "$g_issues" "$base/issues?state=all&type=issues&limit=1" "$MIGRATE_ISSUES"
    cmp_count prs        "$g_prs"    "$base/pulls?state=all&limit=1"              "$MIGRATE_PULL_REQUESTS"
    cmp_count releases   "$g_rel"    "$base/releases?limit=1"                     "$MIGRATE_RELEASES"
    cmp_count labels     "$g_lab"    "$base/labels?limit=1"                       "$MIGRATE_LABELS"
    cmp_count milestones "$g_mil"    "$base/milestones?state=all&limit=1"         "$MIGRATE_MILESTONES"
    cmp_count branches   "$g_br"     "$base/branches?limit=1"                     true
    cmp_count tags       "$g_tag"    "$base/tags?limit=1"                         true

    http_req gitea GET "$GITEA_URL/api/v1/repos/$label"
    if [ "$(printf '%s' "$RESP_BODY" | jq -r '.has_wiki // false')" = "true" ]; then inc count_wikis_enabled; fi

    if [ -n "$VERIFY_MISMATCH" ]; then
        inc count_verified_mismatch
        warn "Count mismatch for $label: $VERIFY_MISMATCH"
        record_failure "Verification mismatch: $label ($VERIFY_MISMATCH)"
        return 1
    else
        inc count_verified_ok
        return 0
    fi
}

# ---------------------------------------------------------------------------
# REPOSITORY PROCESSING
# ---------------------------------------------------------------------------
# process_repos <json array> <gitea target owner> <personal|org>
process_repos() {
    local json="$1" target_owner="$2" scope="$3"
    local repo name gh_full clone_url desc is_private target_private is_archived label state payload rc
    local sync_refs lfs_mode detail

    while IFS= read -r repo; do
        if [ "$scope" = personal ]; then inc count_personal_repos_scanned; else inc count_org_repos_scanned; fi

        name=$(printf '%s' "$repo" | jq -r '.name')
        gh_full=$(printf '%s' "$repo" | jq -r '.full_name')
        clone_url=$(printf '%s' "$repo" | jq -r '.clone_url')
        desc=$(printf '%s' "$repo" | jq -r '.description // ""')
        is_private=$(printf '%s' "$repo" | jq -r '.private')
        target_private=false
        if [ "$is_private" = true ] || [ "$MAKE_PRIVATE" = true ]; then target_private=true; fi
        is_archived=$(printf '%s' "$repo" | jq -r '.archived // false')
        label="$target_owner/$name"

        if [ "$is_private" = true ]; then inc count_repos_private; else inc count_repos_public; fi
        if [ "$is_archived" = true ]; then inc count_repos_archived; fi

        echo "  -> Checking repository: $label..."

        if [ "$DRY_RUN" = true ] && [ "$scope" = org ] && [ "$OVERWRITE_ORGS" = true ] && [ "$ORG_OVERWRITE_DRYRUN_OWNER" = "$target_owner" ]; then
            state=missing
            echo "     [DRY-RUN] treating existing organization repositories as absent after planned org overwrite"
        else
            http_req gitea GET "$GITEA_URL/api/v1/repos/$label"
            case "$RESP_CODE" in
                200) state=exists ;;
                404) state=missing ;;
                *)   inc count_repos_failed; record_failure "Repo Check: $label (HTTP $RESP_CODE $(jmsg))"
                     log_item FAILED repo "$label" "existence check failed"; continue ;;
            esac
        fi

        if [ "$state" = exists ] && [ "$OVERWRITE_REPOS" = true ]; then
            echo "     [OVERWRITE REPO] Deleting existing repository on Gitea..."
            http_req gitea DELETE "$GITEA_URL/api/v1/repos/$label"
            if is_2xx "$RESP_CODE"; then inc count_repos_overwritten; state=missing
            else inc count_repos_failed; record_failure "Repo Delete: $label (HTTP $RESP_CODE $(jmsg))"
                 log_item FAILED repo "$label" "delete failed"; continue
            fi
        fi

        if [ "$state" = exists ]; then
            # Never leave a private source (or force-private migration) public on Gitea.
            if [ "$target_private" = true ]; then
                http_req gitea PATCH "$GITEA_URL/api/v1/repos/$label" '{"private":true}'
                if ! is_2xx "$RESP_CODE"; then
                    inc count_repos_failed
                    record_failure "Repo Privacy: $label could not be made private (HTTP $RESP_CODE $(jmsg)); refusing to continue with this repository"
                    log_item FAILED repo "$label" "could not enforce private visibility"
                    continue
                fi
            fi
            # what to do with a repo that already exists on Gitea
            sync_refs=false; lfs_mode=off
            [ "$SYNC_EXISTING" = git ] && sync_refs=true
            if [ "$MIGRATE_LFS" = true ]; then
                if [ "$OVERWRITE_LFS" = true ]; then lfs_mode=force
                elif [ "$sync_refs" = true ]; then lfs_mode=auto
                fi
            fi

            if [ "$sync_refs" = true ] || [ "$lfs_mode" = force ]; then
                git_sync "$clone_url" "$GITEA_URL/$label.git" "$sync_refs" "$lfs_mode"; rc=$?
                case "$rc" in
                    0) detail=""
                       if [ "$sync_refs" = true ]; then
                           echo "     [SYNC] Branches/tags synced from GitHub."
                           inc count_repos_synced; detail="branches+tags pushed"
                       fi
                       if [ "$GIT_LFS_DONE" = true ]; then
                           echo "     [LFS] All LFS objects re-fetched from GitHub and pushed to Gitea."
                           inc count_repos_lfs_synced; detail="${detail:+$detail, }LFS re-pushed"
                       fi
                       log_item SYNCED repo "$label" "$detail" ;;
                    2) echo "     [SKIP] Already up to date (branches/tags identical)."
                       inc count_repos_uptodate; log_item UPTODATE repo "$label" ;;
                    *) inc count_repos_failed; record_failure "Repo Git Sync: $label ($GIT_ERR)"
                       log_item FAILED repo "$label" "git sync: $GIT_ERR" ;;
                esac
            else
                echo "     [SKIP] Repository already exists (SYNC_EXISTING=skip)."
                inc count_repos_skipped; log_item SKIPPED repo "$label" "already exists"
            fi
            if [ "$VERIFY_ALL" = true ] && [ "$DRY_RUN" != true ]; then
                if verify_repo "${gh_full%%/*}" "$name" "$label"; then
                    log_item VERIFIED repo "$label" "$VERIFY_DETAIL"
                else
                    log_item VERIFY-ERR repo "$label" "${VERIFY_DETAIL:-verification failed} $VERIFY_MISMATCH"
                fi
            fi
            migrate_repo_extras "$gh_full" "$label"
            continue
        fi

        echo "     [MIGRATE] Repository does not exist. Migrating with full payload config..."
        payload=$(jq -n \
            --arg clone "$clone_url" --arg name "$name" --arg owner "$target_owner" --arg desc "$desc" \
            --argjson priv "$target_private" --argjson iss "$MIGRATE_ISSUES" --argjson pr "$MIGRATE_PULL_REQUESTS" \
            --argjson rel "$MIGRATE_RELEASES" --argjson lab "$MIGRATE_LABELS" --argjson mil "$MIGRATE_MILESTONES" \
            --argjson wiki "$MIGRATE_WIKI" --argjson lfs "$MIGRATE_LFS" \
            '{service:"github", clone_addr:$clone, auth_token:$ENV.GITHUB_TOKEN, repo_name:$name, repo_owner:$owner,
              description:$desc, private:$priv, mirror:false, lfs:$lfs, issues:$iss, pull_requests:$pr,
              releases:$rel, labels:$lab, milestones:$mil, wiki:$wiki}')
        http_req gitea POST "$GITEA_URL/api/v1/repos/migrate" "$payload" 7200

        if is_2xx "$RESP_CODE"; then
            inc count_repos_migrated
            if [ "$DRY_RUN" = true ]; then
                log_item WOULD-MIG repo "$label" "dry run"
            else
                sleep 2
                if [ "$VERIFY" = true ]; then
                    if verify_repo "${gh_full%%/*}" "$name" "$label"; then
                        log_item MIGRATED repo "$label" "$VERIFY_DETAIL"
                    else
                        log_item MIGRATED repo "$label" "verification failed: ${VERIFY_DETAIL:-unavailable} $VERIFY_MISMATCH"
                    fi
                else
                    log_item MIGRATED repo "$label" "not verified"
                fi
            fi
            migrate_repo_extras "$gh_full" "$label"
        else
            inc count_repos_failed
            record_failure "Repo Migrate: $label (HTTP $RESP_CODE $(jmsg))"
            log_item FAILED repo "$label" "migration failed"
        fi
    done < <(printf '%s\n' "$json" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT: authentication + rate-limit snapshot + Gitea capabilities
# ---------------------------------------------------------------------------
echo "Logging to: $LOG_FILE"
[ "$DRY_RUN" = true ] && echo ">>> DRY RUN: nothing will be changed on Gitea <<<"

http_req gh GET "https://api.github.com/user"
if ! is_2xx "$RESP_CODE"; then echo "Error: GitHub authentication failed (HTTP $RESP_CODE $(jmsg))"; exit 1; fi
gh_login=$(printf '%s' "$RESP_BODY" | jq -r '.login')
if [ "$(lc "$gh_login")" != "$(lc "$GITHUB_USER")" ]; then
    echo "Error: GITHUB_USER ($GITHUB_USER) does not match the authenticated GitHub account ($gh_login). Fix .env before migrating."
    exit 1
fi

http_req gitea GET "$GITEA_URL/api/v1/user"
if ! is_2xx "$RESP_CODE"; then echo "Error: Gitea authentication failed at $GITEA_URL (HTTP $RESP_CODE $(jmsg))"; exit 1; fi
gitea_login=$(printf '%s' "$RESP_BODY" | jq -r '.login')
if [ "$(lc "$gitea_login")" != "$(lc "$GITEA_USER")" ]; then
    if [ "$MIGRATE_PROJECTS" = true ]; then
        echo "Error: GITEA_USER ($GITEA_USER) differs from the authenticated Gitea account ($gitea_login). User-level Projects are created under the token account; either use a token for GITEA_USER or set MIGRATE_PROJECTS=false."
        exit 1
    else
        warn "GITEA_USER ($GITEA_USER) differs from the authenticated Gitea account ($gitea_login); the token must have permission to create repositories for the configured target owner."
    fi
fi

http_req gitea GET "$GITEA_URL/api/v1/version"
gitea_version=unknown
is_2xx "$RESP_CODE" && gitea_version=$(printf '%s' "$RESP_BODY" | jq -r '.version // "unknown"' 2>/dev/null)

http_req gh GET "https://api.github.com/rate_limit"
rate_start=$(printf '%s' "$RESP_BODY" | jq -r '.resources.core.remaining // "N/A"')
rate_limit=$(printf '%s' "$RESP_BODY" | jq -r '.resources.core.limit // "N/A"')
echo "Authenticated: GitHub=$gh_login  Gitea=$gitea_login (Gitea $gitea_version)  (GitHub quota: $rate_start/$rate_limit)"

if [ "$MIGRATE_PROJECTS" = true ]; then
    http_req gitea GET "$GITEA_URL/api/v1/user/projects?limit=1"
    if is_2xx "$RESP_CODE"; then
        PROJECTS_GITEA=yes
    else
        warn "Gitea $gitea_version has no usable projects API (HTTP $RESP_CODE): needs Gitea 28.0+ with the Projects unit enabled. Projects will be skipped."
    fi
fi

# ---------------------------------------------------------------------------
# 1. PERSONAL REPOSITORIES
# ---------------------------------------------------------------------------
if [ "$MIGRATE_REPOS" = true ]; then
    echo "Fetching personal repositories from GitHub for $GITHUB_USER (affiliation=$GITHUB_AFFILIATION)..."
    if paginate gh "https://api.github.com/user/repos?affiliation=$GITHUB_AFFILIATION"; then
        process_repos "$PAGED_JSON" "$GITEA_USER" personal
    else
        inc count_repos_failed; record_failure "Personal repo listing failed ($PAGED_ERR)"
    fi
else
    echo "Personal repository migration is disabled by MIGRATE_REPOS flag."
fi

# ---------------------------------------------------------------------------
# 2. ORGANIZATIONS
# ---------------------------------------------------------------------------
if [ "$MIGRATE_ORGS" = true ]; then
    echo "Fetching organizations from GitHub..."
    if ! paginate gh "https://api.github.com/user/memberships/orgs?state=active"; then
        inc count_orgs_failed; record_failure "Organization membership listing failed ($PAGED_ERR)"
    else
        # This endpoint works with fine-grained PATs; /user/orgs can silently return [].
        orgs=$(printf '%s' "$PAGED_JSON" | jq -c '[.[] | .organization] | unique_by(.login)')
        while IFS= read -r org; do
            ORG_OVERWRITE_DRYRUN_OWNER=""
            org_name=$(printf '%s' "$org" | jq -r '.login')
            org_desc=$(printf '%s' "$org" | jq -r '.description // "Migrated from GitHub"')
            [ -z "$org_desc" ] && org_desc="Migrated from GitHub"

            echo "Processing GitHub Organization: $org_name"
            inc count_orgs_processed

            http_req gitea GET "$GITEA_URL/api/v1/orgs/$org_name"
            case "$RESP_CODE" in
                200) org_state=exists ;;
                404) org_state=missing ;;
                *)   inc count_orgs_failed; record_failure "Org Check: $org_name (HTTP $RESP_CODE $(jmsg))"
                     log_item FAILED org "$org_name" "existence check failed"; continue ;;
            esac

            if [ "$org_state" = exists ] && [ "$OVERWRITE_ORGS" = true ]; then
                echo "     [OVERWRITE ORG] Removing existing organization repositories before deleting the organization..."
                org_repo_delete_failed=false
                if paginate gitea "$GITEA_URL/api/v1/orgs/$org_name/repos"; then
                    org_existing_repos="$PAGED_JSON"
                    while IFS= read -r org_repo; do
                        [ -z "$org_repo" ] && continue
                        org_repo_full=$(printf '%s' "$org_repo" | jq -r '.full_name // empty')
                        if [ -z "$org_repo_full" ]; then
                            org_repo_delete_failed=true
                            inc count_repos_failed
                            record_failure "Org Repo Delete: $org_name (repository listing returned an item without full_name)"
                            break
                        fi
                        http_req gitea DELETE "$GITEA_URL/api/v1/repos/$org_repo_full"
                        if is_2xx "$RESP_CODE" || [ "$RESP_CODE" = 404 ]; then
                            inc count_repos_overwritten
                            echo "     [OVERWRITE ORG] Deleted repository $org_repo_full"
                        else
                            org_repo_delete_failed=true
                            inc count_repos_failed
                            record_failure "Org Repo Delete: $org_repo_full (HTTP $RESP_CODE $(jmsg))"
                            break
                        fi
                    done < <(printf '%s\n' "$org_existing_repos" | jq -c '.[]')
                else
                    org_repo_delete_failed=true
                    record_failure "Org Repo List before overwrite: $org_name ($PAGED_ERR)"
                fi
                if [ "$org_repo_delete_failed" != true ]; then
                    http_req gitea DELETE "$GITEA_URL/api/v1/orgs/$org_name"
                    if is_2xx "$RESP_CODE" || [ "$RESP_CODE" = 404 ]; then
                        inc count_orgs_overwritten; org_state=missing
                        if [ "$DRY_RUN" = true ]; then ORG_OVERWRITE_DRYRUN_OWNER="$org_name"; fi
                    else
                        inc count_orgs_failed
                        record_failure "Org Delete: $org_name (HTTP $RESP_CODE $(jmsg)) - continuing with the existing org"
                    fi
                else
                    inc count_orgs_failed
                    warn "Organization $org_name was not deleted because one or more repositories could not be removed; continuing with the existing organization."
                fi
            fi

            if [ "$org_state" = missing ]; then
                echo "Creating organization $org_name on Gitea..."
                if [ "$MAKE_PRIVATE" = true ]; then org_vis=private; else org_vis=public; fi
                payload=$(jq -n --arg u "$org_name" --arg d "$org_desc" --arg v "$org_vis" '{username:$u, description:$d, visibility:$v}')
                http_req gitea POST "$GITEA_URL/api/v1/orgs" "$payload"
                if is_2xx "$RESP_CODE"; then
                    inc count_orgs_created; org_state=exists; log_item CREATED org "$org_name"
                else
                    inc count_orgs_failed
                    record_failure "Org Create: $org_name (HTTP $RESP_CODE $(jmsg)) - its repositories were skipped"
                    log_item FAILED org "$org_name" "creation failed; repos skipped"
                    continue
                fi
            else
                inc count_orgs_skipped; log_item SKIPPED org "$org_name" "already exists"
            fi

            # Enforce private visibility on both existing and newly created organizations.
            if [ "$MAKE_PRIVATE" = true ] && [ "$org_state" = exists ]; then
                http_req gitea PATCH "$GITEA_URL/api/v1/orgs/$org_name" '{"visibility":"private"}'
                if ! is_2xx "$RESP_CODE"; then
                    inc count_orgs_failed
                    record_failure "Org Privacy: $org_name could not be made private (HTTP $RESP_CODE $(jmsg)); skipping this organization's webhooks and repositories"
                    continue
                fi
            fi

            if [ "$MIGRATE_ORG_WEBHOOKS" = true ]; then
                migrate_hooks org "https://api.github.com/orgs/$org_name/hooks" "$GITEA_URL/api/v1/orgs/$org_name/hooks" "org:$org_name" "$OVERWRITE_ORG_WEBHOOKS"
            fi

            if paginate gh "https://api.github.com/orgs/$org_name/repos?type=all"; then
                process_repos "$PAGED_JSON" "$org_name" org
            else
                inc count_repos_failed; record_failure "Org repo listing failed for $org_name ($PAGED_ERR)"
            fi
        done < <(printf '%s\n' "$orgs" | jq -c '.[]')
    fi
else
    echo "Organization migration is disabled by MIGRATE_ORGS flag."
fi

# ---------------------------------------------------------------------------
# 3. PROJECTS (after repos/orgs, because items reference migrated issues/PRs)
# ---------------------------------------------------------------------------
if [ "$MIGRATE_PROJECTS" = true ]; then
    if [ "$PROJECTS_GITEA" != yes ]; then
        echo "Project migration skipped: Gitea has no usable projects API (see warnings)."
    else
        migrate_projects_for_owner user "$GITHUB_USER"
        if paginate gh "https://api.github.com/user/memberships/orgs?state=active"; then
            while IFS= read -r proj_org; do
                [ -z "$proj_org" ] && continue
                migrate_projects_for_owner org "$proj_org"
            done < <(printf '%s\n' "$PAGED_JSON" | jq -r '.[].organization.login | select(. != null)')
        else
            warn "Could not list organizations for project migration ($PAGED_ERR)"
        fi
    fi
else
    echo "Project migration is disabled by MIGRATE_PROJECTS flag."
fi

# ---------------------------------------------------------------------------
# 4. GISTS
# ---------------------------------------------------------------------------
if [ "$MIGRATE_GISTS" = true ]; then
    echo "Fetching Gists from GitHub..."
    if ! paginate gh "https://api.github.com/gists"; then
        inc count_gists_failed; record_failure "Gist listing failed ($PAGED_ERR)"
    else
        gists="$PAGED_JSON"
        while IFS= read -r gist; do
            inc count_gists_scanned
            gist_id=$(printf '%s' "$gist" | jq -r '.id')
            gist_desc=$(printf '%s' "$gist" | jq -r '.description // ""')
            gist_public=$(printf '%s' "$gist" | jq -r '.public')
            gist_private=true
            if [ "$gist_public" = true ] && [ "$MAKE_PRIVATE" != true ]; then gist_private=false; fi
            gist_clone=$(printf '%s' "$gist" | jq -r '.git_pull_url')
            if [ "$gist_public" = true ]; then inc count_gists_public; else inc count_gists_secret; fi

            slug=$(printf '%s' "$gist_desc" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g' | cut -c 1-30 | sed -E 's/-+$//')
            gist_name="gist-${slug:+$slug-}${gist_id:0:8}"
            glabel="$GITEA_USER/$gist_name"

            echo "  -> Checking Gist: $gist_id ($gist_name)..."
            http_req gitea GET "$GITEA_URL/api/v1/repos/$glabel"
            case "$RESP_CODE" in
                200) gstate=exists ;;
                404) gstate=missing ;;
                *)   inc count_gists_failed; record_failure "Gist Check: $gist_name (HTTP $RESP_CODE $(jmsg))"
                     log_item FAILED gist "$gist_name" "existence check failed"; continue ;;
            esac

            if [ "$gstate" = exists ] && [ "$OVERWRITE_GISTS" = true ]; then
                echo "     [OVERWRITE GIST] Deleting existing Gist repository: $gist_name"
                http_req gitea DELETE "$GITEA_URL/api/v1/repos/$glabel"
                if is_2xx "$RESP_CODE"; then inc count_gists_overwritten; gstate=missing
                else inc count_gists_failed; record_failure "Gist Delete: $gist_name (HTTP $RESP_CODE $(jmsg))"
                     log_item FAILED gist "$gist_name" "delete failed"; continue
                fi
            fi

            if [ "$gstate" = exists ]; then
                # Secret (unlisted) GitHub Gists are made private on Gitea to avoid exposure.
                if [ "$gist_private" = true ]; then
                    http_req gitea PATCH "$GITEA_URL/api/v1/repos/$glabel" '{"private":true}'
                    if ! is_2xx "$RESP_CODE"; then
                        inc count_gists_failed
                        record_failure "Gist Privacy: $gist_name could not be made private (HTTP $RESP_CODE $(jmsg)); refusing to continue with this Gist"
                        log_item FAILED gist "$gist_name" "could not enforce private visibility"
                        continue
                    fi
                fi
                if [ "$SYNC_EXISTING" = git ]; then
                    git_sync "$gist_clone" "$GITEA_URL/$glabel.git" true off; rc=$?
                    case "$rc" in
                        0) inc count_gists_synced; log_item SYNCED gist "$gist_name" ;;
                        2) inc count_gists_uptodate; log_item UPTODATE gist "$gist_name" ;;
                        *) inc count_gists_failed; record_failure "Gist Git Sync: $gist_name ($GIT_ERR)"
                           log_item FAILED gist "$gist_name" "git sync failed" ;;
                    esac
                else
                    echo "     [SKIP] Gist repository already exists on Gitea."
                    inc count_gists_skipped; log_item SKIPPED gist "$gist_name" "already exists"
                fi
            else
                echo "     [MIGRATE] Migrating Gist as repository..."
                payload=$(jq -n --arg clone "$gist_clone" --arg name "$gist_name" --arg owner "$GITEA_USER" \
                    --arg desc "$gist_desc" --argjson priv "$gist_private" \
                    '{service:"git", clone_addr:$clone, auth_username:$ENV.GITHUB_USER, auth_password:$ENV.GITHUB_TOKEN,
                      repo_name:$name, repo_owner:$owner, description:$desc, private:$priv, mirror:false}')
                http_req gitea POST "$GITEA_URL/api/v1/repos/migrate" "$payload" 1800
                if is_2xx "$RESP_CODE"; then
                    inc count_gists_migrated; log_item MIGRATED gist "$gist_name"
                else
                    inc count_gists_failed; record_failure "Gist Migrate: $gist_name (HTTP $RESP_CODE $(jmsg))"
                    log_item FAILED gist "$gist_name" "migration failed"
                fi
            fi
        done < <(printf '%s\n' "$gists" | jq -c '.[]')
    fi
else
    echo "Gist migration is disabled by MIGRATE_GISTS flag."
fi

# ---------------------------------------------------------------------------
# FINAL STATS
# ---------------------------------------------------------------------------
http_req gh GET "https://api.github.com/rate_limit"
rate_end=$(printf '%s' "$RESP_BODY" | jq -r '.resources.core.remaining // "N/A"')
if [ "$rate_start" != "N/A" ] && [ "$rate_end" != "N/A" ]; then rate_used=$((rate_start - rate_end)); else rate_used="N/A"; fi

END_TIME=$(date +%s)
END_DATE=$(date "+%Y-%m-%d %H:%M:%S")
ELAPSED=$((END_TIME - START_TIME))
TOTAL_REPOS_SCANNED=$((count_personal_repos_scanned + count_org_repos_scanned))
TOTAL_ERRORS=${#failed_items[@]}

row() { printf '    %s %-30s %s\n' "$1" "$2" "$3"; }
sep() { echo "------------------------------------------------------------"; }

echo ""
echo "============================================================"
echo "              COMPREHENSIVE EXECUTION SUMMARY               "
echo "============================================================"
if [ "$DRY_RUN" = true ]; then
echo "  *** DRY RUN - no changes were made; 'migrated/created/overwritten' = planned actions ***"
fi
echo "  Source GitHub User:            $GITHUB_USER"
echo "  Target Gitea Instance:         $GITEA_URL (User: $GITEA_USER, version $gitea_version)"
echo "  Force-private destinations (MAKE_PRIVATE): $MAKE_PRIVATE (private repos/secret Gists stay private regardless)"
echo "  Existing-repo strategy:        SYNC_EXISTING=$SYNC_EXISTING | OVERWRITE_LFS=$OVERWRITE_LFS | VERIFY=$VERIFY | VERIFY_ALL=$VERIFY_ALL"
echo "  Started At:                    $START_DATE"
echo "  Finished At:                   $END_DATE (${ELAPSED}s elapsed)"
echo "  GitHub API calls (this script):$count_gh_calls"
echo "  GitHub quota (start -> end):   $rate_start -> $rate_end of $rate_limit (used: $rate_used)"
echo "  Log file:                      $LOG_FILE"
sep
echo "  ORGANIZATIONS ($(onoff "$MIGRATE_ORGS") | Overwrite: $(onoff "$OVERWRITE_ORGS"))"
row "├──" "Scanned / Processed:" "$count_orgs_processed"
row "├──" "Newly Created:" "$count_orgs_created"
row "├──" "Existing (Skipped):" "$count_orgs_skipped"
row "├──" "Overwritten:" "$count_orgs_overwritten"
row "└──" "Failed:" "$count_orgs_failed"
sep
echo "  ORG WEBHOOKS ($(onoff "$MIGRATE_ORG_WEBHOOKS") | Overwrite: $(onoff "$OVERWRITE_ORG_WEBHOOKS") | Create inactive: $(onoff "$HOOKS_CREATE_INACTIVE"))"
row "├──" "Migrated (New):" "$count_org_webhooks_migrated"
row "├──" "Skipped (Existing):" "$count_org_webhooks_skipped"
row "├──" "Overwritten:" "$count_org_webhooks_overwritten"
row "└──" "Failed:" "$count_org_webhooks_failed"
sep
echo "  REPOSITORIES (Personal: $(onoff "$MIGRATE_REPOS") | Orgs: $(onoff "$MIGRATE_ORGS") | Overwrite: $(onoff "$OVERWRITE_REPOS") | LFS: $(onoff "$MIGRATE_LFS") | Overwrite LFS: $(onoff "$OVERWRITE_LFS"))"
row "├──" "Total Scanned:" "$TOTAL_REPOS_SCANNED (Personal: $count_personal_repos_scanned, Org: $count_org_repos_scanned)"
row "├──" "Visibility on GitHub:" "private=$count_repos_private public=$count_repos_public archived=$count_repos_archived"
row "├──" "Migrated (New):" "$count_repos_migrated"
row "├──" "Git-Synced (existing):" "$count_repos_synced"
row "├──" "LFS Re-pushed (existing):" "$count_repos_lfs_synced"
row "├──" "Already Up-to-Date:" "$count_repos_uptodate"
row "├──" "Skipped (existing):" "$count_repos_skipped"
row "├──" "Overwritten:" "$count_repos_overwritten"
row "└──" "Failed:" "$count_repos_failed"
sep
echo "  VERIFICATION (repos checked: OK=$count_verified_ok, mismatch=$count_verified_mismatch, unreadable=$count_verified_error)"
echo "    Totals over verified repos only; GitHub counts include closed items; PRs counted separately from issues."
printf '    %-12s GitHub=%-8s Gitea=%-8s (flag: %s)\n' "Issues:"     "$tot_gh_issues"     "$tot_gitea_issues"     "$(onoff "$MIGRATE_ISSUES")"
printf '    %-12s GitHub=%-8s Gitea=%-8s (flag: %s)\n' "Pull reqs:"  "$tot_gh_prs"        "$tot_gitea_prs"        "$(onoff "$MIGRATE_PULL_REQUESTS")"
printf '    %-12s GitHub=%-8s Gitea=%-8s (flag: %s)\n' "Releases:"   "$tot_gh_releases"   "$tot_gitea_releases"   "$(onoff "$MIGRATE_RELEASES")"
printf '    %-12s GitHub=%-8s Gitea=%-8s (flag: %s)\n' "Labels:"     "$tot_gh_labels"     "$tot_gitea_labels"     "$(onoff "$MIGRATE_LABELS")"
printf '    %-12s GitHub=%-8s Gitea=%-8s (flag: %s)\n' "Milestones:" "$tot_gh_milestones" "$tot_gitea_milestones" "$(onoff "$MIGRATE_MILESTONES")"
printf '    %-12s GitHub=%-8s Gitea=%-8s\n'            "Branches:"   "$tot_gh_branches"   "$tot_gitea_branches"
printf '    %-12s GitHub=%-8s Gitea=%-8s\n'            "Tags:"       "$tot_gh_tags"       "$tot_gitea_tags"
printf '    %-12s %s (flag: %s)\n'                     "Wikis on:"   "$count_wikis_enabled repos" "$(onoff "$MIGRATE_WIKI")"
echo "    Issue/PR comments and reviews are imported by Gitea but are not counted here."
sep
echo "  PROJECTS ($(onoff "$MIGRATE_PROJECTS") | Overwrite: $(onoff "$OVERWRITE_PROJECTS") | Gitea projects API: $PROJECTS_GITEA | Column field: $PROJECTS_STATUS_FIELD)"
row "├──" "Total Scanned:" "$count_projects_scanned"
row "├──" "Migrated (New):" "$count_projects_migrated"
row "├──" "Skipped (Existing):" "$count_projects_skipped"
row "├──" "Overwritten:" "$count_projects_overwritten"
row "├──" "Failed:" "$count_projects_failed"
row "├──" "Items placed on boards:" "$count_project_items_added"
row "├──" "Items skipped (draft/foreign):" "$count_project_items_skipped"
row "├──" "Items not found on Gitea:" "$count_project_items_missing"
row "└──" "Items failed:" "$count_project_items_failed"
sep
echo "  REPO WEBHOOKS ($(onoff "$MIGRATE_WEBHOOKS") | Overwrite: $(onoff "$OVERWRITE_WEBHOOKS") | Create inactive: $(onoff "$HOOKS_CREATE_INACTIVE"))"
row "├──" "Migrated (New):" "$count_repo_webhooks_migrated"
row "├──" "Skipped (Existing):" "$count_repo_webhooks_skipped"
row "├──" "Overwritten:" "$count_repo_webhooks_overwritten"
row "└──" "Failed:" "$count_repo_webhooks_failed"
sep
echo "  DEPLOY KEYS ($(onoff "$MIGRATE_DEPLOY_KEYS") | Overwrite: $(onoff "$OVERWRITE_DEPLOY_KEYS"))"
row "├──" "Migrated (New):" "$count_keys_migrated"
row "├──" "Skipped (Existing):" "$count_keys_skipped"
row "├──" "Overwritten:" "$count_keys_overwritten"
row "└──" "Failed:" "$count_keys_failed"
sep
echo "  GISTS ($(onoff "$MIGRATE_GISTS") | Overwrite: $(onoff "$OVERWRITE_GISTS"))"
row "├──" "Total Scanned:" "$count_gists_scanned (public: $count_gists_public, secret: $count_gists_secret)"
row "├──" "Migrated (New):" "$count_gists_migrated"
row "├──" "Git-Synced (existing):" "$count_gists_synced"
row "├──" "Already Up-to-Date:" "$count_gists_uptodate"
row "├──" "Skipped (Existing):" "$count_gists_skipped"
row "├──" "Overwritten:" "$count_gists_overwritten"
row "└──" "Failed:" "$count_gists_failed"
echo "============================================================"

if [ ${#item_log[@]} -gt 0 ]; then
    echo "  PER-ITEM LOG (${#item_log[@]} items)"
    printf '    %-10s %-7s %-48s %s\n' "STATUS" "TYPE" "ITEM" "DETAIL"
    for line in "${item_log[@]}"; do echo "    $line"; done
    echo "============================================================"
fi

if [ ${#warnings[@]} -gt 0 ]; then
    echo "  WARNINGS (${#warnings[@]}):"
    for w in "${warnings[@]}"; do echo "    ! $w"; done
    echo "============================================================"
fi

echo "  PRIVACY NOTE: GitHub secret (unlisted) Gists are migrated as private Gitea repositories."
echo "  MAKE_PRIVATE=true forces destination repositories/Gists and organizations private;"
echo "  MAKE_PRIVATE=false preserves private source repositories/Gists as private but permits public sources."
echo "  NOT MIGRATED BY THIS SCRIPT (handle manually if needed):"
echo "    - Webhook secrets (GitHub never returns them; re-enter in Gitea)"
echo "    - Classic (pre-v2) project boards (sunset by GitHub); Projects v2 views, custom fields"
echo "      other than the '$PROJECTS_STATUS_FIELD' columns, workflows/automations, draft items,"
echo "      and items whose repo belongs to a different owner than the project"
echo "    - GitHub Actions workflows' secrets/variables/runs (workflow files travel with the repo)"
echo "    - Branch protection rules, rulesets, CODEOWNERS enforcement"
echo "    - Collaborators, teams, org members and permissions"
echo "    - Discussions, Packages/Container registry, Pages, Dependabot settings"
echo "    - Stars, watchers, followers, repo-level topics/avatars"
echo "    - Repos where you are only a collaborator (set GITHUB_AFFILIATION=owner,collaborator to include)"
echo "    - Repos beyond what the token can see (private orgs needing SSO authorization)"
echo "    - LFS objects that already exist on Gitea are never replaced (same OID = same content)"
echo "============================================================"

if [ "$TOTAL_ERRORS" -gt 0 ]; then
    echo "  FAILED ITEMS ($TOTAL_ERRORS):"
    for item in "${failed_items[@]}"; do echo "    x $item"; done
    echo "============================================================"
    echo "Completed with $TOTAL_ERRORS error(s)."
    sleep 1
    exit 1
else
    echo "All synchronization and migration tasks completed with 0 errors!"
    sleep 1
    exit 0
fi