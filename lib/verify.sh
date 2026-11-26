# Sourced by run.sh.
# Post-migration count verification: GitHub GraphQL vs Gitea X-Total-Count headers.
#
# Uses: http_req, inc, warn, record_failure, is_2xx, jmsg.
# Reads globals: GITEA_URL, MIGRATE_* flags.

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
