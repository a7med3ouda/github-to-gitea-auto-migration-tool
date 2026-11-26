# Sourced by run.sh.
# Organization migration: create/overwrite org, migrate org webhooks, migrate
# the org's repositories.
#
# Uses: http_req, paginate, process_repos, migrate_hooks, inc, warn,
#       record_failure, log_item, is_2xx, jmsg.
# Reads globals: GITEA_URL, DRY_RUN, ORG_VISIBILITY, OVERWRITE_ORGS,
#                MIGRATE_ORG_WEBHOOKS, OVERWRITE_ORG_WEBHOOKS, MIGRATE_ORGS,
#                ORG_OVERWRITE_DRYRUN_OWNER (mutated per-iteration).

migrate_orgs() {
    if [ "$MIGRATE_ORGS" != true ]; then
        echo "Organization migration is disabled by MIGRATE_ORGS flag."
        return
    fi

    echo "Fetching organizations from GitHub..."
    if ! paginate gh "https://api.github.com/user/memberships/orgs?state=active"; then
        inc count_orgs_failed; record_failure "Organization membership listing failed ($PAGED_ERR)"
        return
    fi

    # This endpoint works with fine-grained PATs; /user/orgs can silently return [].
    local orgs
    orgs=$(printf '%s' "$PAGED_JSON" | jq -c '[.[] | .organization] | unique_by(.login)')
    local org
    while IFS= read -r org; do
        ORG_OVERWRITE_DRYRUN_OWNER=""
        local org_name org_desc org_state org_existing_repos org_repo org_repo_full org_repo_delete_failed
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
            echo "Creating organization $org_name on Gitea (visibility=$ORG_VISIBILITY)..."
            local payload
            payload=$(jq -n --arg u "$org_name" --arg d "$org_desc" --arg v "$ORG_VISIBILITY" '{username:$u, description:$d, visibility:$v}')
            http_req gitea POST "$GITEA_URL/api/v1/orgs" "$payload"
            if is_2xx "$RESP_CODE"; then
                inc count_orgs_created; org_state=exists; log_item CREATED org "$org_name" "visibility=$ORG_VISIBILITY"
            else
                inc count_orgs_failed
                record_failure "Org Create: $org_name (HTTP $RESP_CODE $(jmsg)) - its repositories were skipped"
                log_item FAILED org "$org_name" "creation failed; repos skipped"
                continue
            fi
        else
            inc count_orgs_skipped; log_item SKIPPED org "$org_name" "already exists"
        fi

        # Newly created orgs already got ORG_VISIBILITY at creation time; for existing
        # orgs we only ever tighten to private, never loosen.
        if [ "$ORG_VISIBILITY" = private ] && [ "$org_state" = exists ]; then
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
}
