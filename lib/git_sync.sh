# Sourced by run.sh.
# Mirror-based branch/tag sync and LFS re-push.
#
# Reads globals: TMP_DIR, GITEA_URL, DRY_RUN.
# Uses: warn (from lib/utils.sh).

GIT_ERR=""; GIT_LFS_DONE=false
G() { git -c credential.helper= "$@"; }
git_refs() { G ls-remote --heads --tags "$1" </dev/null 2>/dev/null | sort; }

# git_sync <src> <dst> <do_refs true|false> <lfs_mode off|auto|force>
#   do_refs  : compare refs and push branches + tags (with prune)
#   lfs_mode : off   = never touch LFS
#              auto  = push LFS objects only when refs changed
#              force = always fetch ALL LFS objects from GitHub and push them
#                      to Gitea (OVERWRITE_LFS); failures are errors
#   returns 0 = did something, 2 = nothing to do (already up to date), 1 = failed
#   sets GIT_ERR and GIT_LFS_DONE (true when LFS objects were (or would be) pushed)
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
