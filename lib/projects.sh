# Sourced by run.sh.
# GitHub Projects v2 (GraphQL) -> Gitea project boards (REST, Gitea 28.4.0+).
#
# * user-level GitHub projects  -> /api/v1/user/projects         (token owner)
# * org-level  GitHub projects  -> /api/v1/orgs/{org}/projects
# * options of PROJECTS_STATUS_FIELD single-select field become columns
#   (in board order); items without a status go to a "No Status" column
# * Issue / PR items are placed in their column. Draft items, redacted items and
#   items whose repo belongs to a different owner than the project cannot be
#   represented in Gitea and are counted as skipped.
# * Existing Gitea boards are matched by a <!-- github-project-id:... --> marker
#   in the description (skipped, or deleted and recreated with
#   OVERWRITE_PROJECTS=true). A same-title board without the marker is only
#   warned about and skipped, never deleted.
# * Classic (pre-v2) projects are not migrated: GitHub sunset them.
#
# Uses: http_req, paginate, inc, warn, record_failure, is_2xx, jmsg,
#       gitea_owner_for, lc.
# Reads globals: GITEA_URL, GITEA_USER, GITHUB_USER, DRY_RUN,
#                PROJECTS_STATUS_FIELD, OVERWRITE_PROJECTS, MIGRATE_PROJECTS.

NOSTATUS_COL="No Status"
PROJECTS_GITEA=no
GITEA_PROJECTS='[]'

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

    # existing Gitea projects (open + closed), matched later by source marker
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

# migrate_all_projects  (top-level Projects step in the main flow)
migrate_all_projects() {
    if [ "$MIGRATE_PROJECTS" != true ]; then
        echo "Project migration is disabled by MIGRATE_PROJECTS flag."; return
    fi
    if [ "$PROJECTS_GITEA" != yes ]; then
        echo "Project migration skipped: Gitea has no usable projects API (see warnings)."; return
    fi
    migrate_projects_for_owner user "$GITHUB_USER"
    local proj_org
    if paginate gh "https://api.github.com/user/memberships/orgs?state=active"; then
        while IFS= read -r proj_org; do
            [ -z "$proj_org" ] && continue
            migrate_projects_for_owner org "$proj_org"
        done < <(printf '%s\n' "$PAGED_JSON" | jq -r '.[].organization.login | select(. != null)')
    else
        warn "Could not list organizations for project migration ($PAGED_ERR)"
    fi
}
