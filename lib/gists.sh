# Sourced by run.sh.
# Gist migration: each Gist is imported as a Gitea Git repository.
#
# Secret (unlisted) GitHub Gists are made private on Gitea to avoid exposure.
#
# Uses: http_req, paginate, inc, warn, record_failure, log_item, is_2xx, jmsg,
#       git_sync.
# Reads globals: GITEA_URL, GITEA_USER, GITHUB_USER, DRY_RUN, FORCE_PRIVATE,
#                MIGRATE_GISTS, OVERWRITE_GISTS, SYNC_EXISTING.

migrate_gists() {
    if [ "$MIGRATE_GISTS" != true ]; then
        echo "Gist migration is disabled by MIGRATE_GISTS flag."
        return
    fi

    echo "Fetching Gists from GitHub..."
    if ! paginate gh "https://api.github.com/gists"; then
        inc count_gists_failed; record_failure "Gist listing failed ($PAGED_ERR)"
        return
    fi

    local gists gist gist_id gist_desc gist_public gist_private gist_clone
    local slug gist_name glabel gstate payload rc
    gists="$PAGED_JSON"
    while IFS= read -r gist; do
        inc count_gists_scanned
        gist_id=$(printf '%s' "$gist" | jq -r '.id')
        gist_desc=$(printf '%s' "$gist" | jq -r '.description // ""')
        gist_public=$(printf '%s' "$gist" | jq -r '.public')
        gist_private=true
        if [ "$gist_public" = true ] && [ "$FORCE_PRIVATE" != true ]; then gist_private=false; fi
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
}
