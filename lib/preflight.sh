# Sourced by run.sh.
# Authentication check + rate-limit snapshot + Gitea capabilities probe.
#
# Uses: http_req, is_2xx, jmsg, warn, lc.
# Reads globals: GITHUB_USER, GITEA_USER, GITEA_URL, MIGRATE_PROJECTS, DRY_RUN.
# Sets globals used later by summary: gh_login, gitea_login, gitea_version,
#                                     rate_start, rate_limit, PROJECTS_GITEA.

preflight() {
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
            warn "Gitea $gitea_version has no usable projects API (HTTP $RESP_CODE): needs Gitea 28.4.0+ with the Projects unit enabled. Projects will be skipped."
        fi
    fi
}
