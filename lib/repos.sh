# Sourced by run.sh.
# Per-repository migration, existing-repo sync, and repo-level extras.
#
# Uses: http_req, inc, warn, record_failure, log_item, is_2xx, jmsg,
#       git_sync, verify_repo, migrate_hooks, migrate_keys.
# Reads globals: GITEA_URL, GITEA_USER, DRY_RUN, SYNC_EXISTING,
#                OVERWRITE_*, MIGRATE_*, FORCE_PRIVATE, VERIFY, VERIFY_ALL,
#                ORG_OVERWRITE_DRYRUN_OWNER.

migrate_repo_extras() {
    local gh_full="$1" label="$2"
    if [ "$MIGRATE_WEBHOOKS" = true ]; then
        migrate_hooks repo "https://api.github.com/repos/$gh_full/hooks" "$GITEA_URL/api/v1/repos/$label/hooks" "$label" "$OVERWRITE_WEBHOOKS"
    fi
    if [ "$MIGRATE_DEPLOY_KEYS" = true ]; then
        migrate_keys "https://api.github.com/repos/$gh_full/keys" "$GITEA_URL/api/v1/repos/$label/keys" "$label"
    fi
}

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
        if [ "$is_private" = true ] || [ "$FORCE_PRIVATE" = true ]; then target_private=true; fi
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

# migrate_personal_repos  (top-level Personal step in the main flow)
migrate_personal_repos() {
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
}
