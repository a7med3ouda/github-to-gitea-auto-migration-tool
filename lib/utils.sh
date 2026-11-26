# Sourced by run.sh.
# Small helpers: counter increment, HTTP-class test, failure/warning trackers,
# per-item log, boolean -> ON/OFF, lowercase, and GitHub-owner -> Gitea-owner.
#
# These functions reference globals initialized in lib/logging.sh
# (failed_items, warnings, item_log) and lib/config.sh (GITHUB_USER, GITEA_USER).

inc() { printf -v "$1" '%d' $(( ${!1} + ${2:-1} )); }
is_2xx() { case "$1" in 2??) return 0 ;; *) return 1 ;; esac; }
record_failure() { failed_items+=("$1"); echo "     [ERROR] $1"; }
warn() { warnings+=("$1"); echo "     [WARN] $1"; }
log_item() { item_log+=("$(printf '%-10s %-7s %-48s %s' "$1" "$2" "$3" "${4:-}")"); }
onoff() { if [ "$1" = true ]; then echo ON; else echo OFF; fi; }
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# GitHub owner -> Gitea owner (personal repos live under GITEA_USER, orgs keep their name)
gitea_owner_for() {
    if [ "$(lc "$1")" = "$(lc "$GITHUB_USER")" ]; then printf '%s' "$GITEA_USER"; else printf '%s' "$1"; fi
}
