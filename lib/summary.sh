# Sourced by run.sh.
# Final execution summary + per-item log + warnings + failed items.
# Terminates the whole script (`exit 0` / `exit 1`) so the EXIT trap from
# logging.sh runs.
#
# Uses: http_req.
# Reads globals: all counters, failed_items, warnings, item_log,
#                GITHUB_USER, GITEA_USER, GITEA_URL, gitea_version,
#                rate_start, rate_limit, START_TIME, START_DATE,
#                FORCE_PRIVATE, ORG_VISIBILITY, SYNC_EXISTING, OVERWRITE_LFS, VERIFY,
#                VERIFY_ALL, DRY_RUN, MIGRATE_*, OVERWRITE_*, PROJECTS_*,
#                HOOKS_CREATE_INACTIVE, PROJECTS_STATUS_FIELD.

row() { printf '    %s %-30s %s\n' "$1" "$2" "$3"; }
sep() { echo "------------------------------------------------------------"; }

print_summary() {
    http_req gh GET "https://api.github.com/rate_limit"
    rate_end=$(printf '%s' "$RESP_BODY" | jq -r '.resources.core.remaining // "N/A"')
    if [ "$rate_start" != "N/A" ] && [ "$rate_end" != "N/A" ]; then rate_used=$((rate_start - rate_end)); else rate_used="N/A"; fi

    END_TIME=$(date +%s)
    END_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    ELAPSED=$((END_TIME - START_TIME))
    TOTAL_REPOS_SCANNED=$((count_personal_repos_scanned + count_org_repos_scanned))
    TOTAL_ERRORS=${#failed_items[@]}

    echo ""
    echo "============================================================"
    echo "              COMPREHENSIVE EXECUTION SUMMARY               "
    echo "============================================================"
    if [ "$DRY_RUN" = true ]; then
    echo "  *** DRY RUN - no changes were made; 'migrated/created/overwritten' = planned actions ***"
    fi
    echo "  Source GitHub User:            $GITHUB_USER"
    echo "  Target Gitea Instance:         $GITEA_URL (User: $GITEA_USER, version $gitea_version)"
    echo "  Visibility mode (FORCE_PRIVATE): $FORCE_PRIVATE ($( [ "$FORCE_PRIVATE" = true ] && echo "everything forced private" || echo "follows GitHub: private stays private, public stays public; secret Gists always private" ))"
    echo "  New organization visibility: $ORG_VISIBILITY (ORG_VISIBILITY setting, resolved from 'auto' if applicable)"
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
    echo "  FORCE_PRIVATE=false (default) follows GitHub: private repos/Gists stay private, public ones stay public."
    echo "  FORCE_PRIVATE=true forces destination repositories/Gists and organizations private."
    echo "  ORG_VISIBILITY sets the visibility of newly created organizations (GitHub exposes no org visibility to copy);"
    echo "  existing Gitea organizations are only ever tightened to private, never made more public."
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
}
