# Sourced by run.sh.
# Loads .env, applies defaults, validates configuration, and prompts for
# confirmation of destructive options. Runs BEFORE logging starts, so the
# confirmation prompt is not buffered by tee.
#
# Reads from parent shell: DRY_RUN_FLAG, ASSUME_YES_FLAG, SCRIPT_DIR.

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
    echo "Loading configuration from $ENV_FILE ..."
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
else
    echo "Error: $ENV_FILE not found! (set ENV_FILE=/path/to/file to use another location)"
    exit 1
fi

FORCE_PRIVATE="${FORCE_PRIVATE:-false}"
ORG_VISIBILITY="${ORG_VISIBILITY:-auto}"
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

BOOL_VARS="FORCE_PRIVATE MIGRATE_REPOS MIGRATE_ORGS MIGRATE_GISTS MIGRATE_ISSUES MIGRATE_PULL_REQUESTS
MIGRATE_RELEASES MIGRATE_LABELS MIGRATE_MILESTONES MIGRATE_WIKI MIGRATE_LFS MIGRATE_WEBHOOKS
MIGRATE_ORG_WEBHOOKS MIGRATE_DEPLOY_KEYS MIGRATE_PROJECTS OVERWRITE_REPOS OVERWRITE_ORGS
OVERWRITE_GISTS OVERWRITE_WEBHOOKS OVERWRITE_ORG_WEBHOOKS OVERWRITE_DEPLOY_KEYS OVERWRITE_PROJECTS
OVERWRITE_LFS VERIFY VERIFY_ALL HOOKS_CREATE_INACTIVE DRY_RUN ASSUME_YES ALLOW_INSECURE_HTTP"
for v in $BOOL_VARS; do normalize_bool "$v" || exit 1; done

case "$SYNC_EXISTING" in skip|git) ;; *) echo "Error: SYNC_EXISTING must be 'skip' or 'git'"; exit 1 ;; esac

# ORG_VISIBILITY applies to NEWLY CREATED Gitea organizations (GitHub has no org visibility to copy).
#   auto = private if FORCE_PRIVATE=true, otherwise public
ORG_VISIBILITY=$(printf '%s' "$ORG_VISIBILITY" | tr '[:upper:]' '[:lower:]')
case "$ORG_VISIBILITY" in
    auto)
        if [ "$FORCE_PRIVATE" = true ]; then ORG_VISIBILITY=private; else ORG_VISIBILITY=public; fi ;;
    private|limited|public) ;;
    *) echo "Error: ORG_VISIBILITY must be auto, private, limited or public (got '$ORG_VISIBILITY')"; exit 1 ;;
esac
if [ "$FORCE_PRIVATE" = true ] && [ "$ORG_VISIBILITY" != private ]; then
    echo "Error: ORG_VISIBILITY=$ORG_VISIBILITY conflicts with FORCE_PRIVATE=true (which forces everything private)."
    echo "       Set FORCE_PRIVATE=false, or use ORG_VISIBILITY=private/auto."
    exit 1
fi

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
