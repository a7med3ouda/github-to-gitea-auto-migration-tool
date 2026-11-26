# Sourced by run.sh.
# Repo/org webhook migration: GitHub events -> Gitea events, URL dedup,
# optional overwrite semantics.
#
# Uses: paginate, http_req, inc, warn, record_failure, is_2xx, jmsg (utils/http).
# Reads globals: GITEA_URL, DRY_RUN, HOOKS_CREATE_INACTIVE.

EVENT_MAP_JQ='
def m: {
  "push":["push"],"create":["create"],"delete":["delete"],"fork":["fork"],
  "issues":["issues","issue_assign","issue_label","issue_milestone"],
  "issue_comment":["issue_comment"],
  "pull_request":["pull_request","pull_request_assign","pull_request_label","pull_request_milestone","pull_request_sync"],
  "pull_request_review":["pull_request_review_approved","pull_request_review_rejected"],
  "pull_request_review_comment":["pull_request_review_comment"],
  "gollum":["wiki"],"repository":["repository"],"release":["release"]
};
(.events // ["push"]) as $e
| (if ($e | index("*")) != null then ([(m)[]] | add | unique)
   else ([ $e[] | ((m)[.] // []) ] | add // []) | unique end)
| if length == 0 then ["push"] else . end'

# migrate_hooks <repo|org> <github hooks url> <gitea hooks url> <label> <overwrite true|false>
migrate_hooks() {
    local scope="$1" gh_url="$2" gitea_url="$3" label="$4" overwrite="$5"
    local gh_hooks gitea_hooks hook hook_url hook_ct hook_active hook_events hook_unknown exists payload

    if ! paginate gh "$gh_url"; then
        if [ "$PAGED_CODE" = 403 ] || [ "$PAGED_CODE" = 404 ]; then
            warn "Webhooks of $label not readable (HTTP $PAGED_CODE): token lacks hook-admin permission; skipped."
        else
            inc "count_${scope}_webhooks_failed"; record_failure "Webhook List ($scope): $label ($PAGED_ERR)"
        fi
        return
    fi
    gh_hooks="$PAGED_JSON"
    [ "$(printf '%s' "$gh_hooks" | jq 'length')" -eq 0 ] && return

    if ! paginate gitea "$gitea_url"; then
        if [ "$DRY_RUN" = true ]; then PAGED_JSON='[]'
        else inc "count_${scope}_webhooks_failed"; record_failure "Webhook List on Gitea ($scope): $label ($PAGED_ERR)"; return
        fi
    fi
    gitea_hooks="$PAGED_JSON"

    while IFS= read -r hook; do
        hook_url=$(printf '%s' "$hook" | jq -r '.config.url // empty')
        [ -z "$hook_url" ] && continue
        hook_ct=$(printf '%s' "$hook" | jq -r '.config.content_type // "json"')
        hook_active=$(printf '%s' "$hook" | jq -r 'if .active == null then true else .active end')
        [ "$HOOKS_CREATE_INACTIVE" = true ] && hook_active=false
        hook_unknown=$(printf '%s' "$hook" | jq -r '
            def m: {"push":1,"create":1,"delete":1,"fork":1,"issues":1,"issue_comment":1,"pull_request":1,"pull_request_review":1,"pull_request_review_comment":1,"gollum":1,"repository":1,"release":1};
            (.events // ["push"]) as $e
            | if ($e | index("*")) != null then ""
              else [$e[] | select((m[.] // null) == null)] | unique | join(", ") end')
        if [ -n "$hook_unknown" ]; then
            warn "Webhook $label -> $hook_url uses unsupported GitHub event(s): $hook_unknown; skipped rather than mapped incorrectly."
            inc "count_${scope}_webhooks_skipped"
            continue
        fi
        hook_events=$(printf '%s' "$hook" | jq -c "$EVENT_MAP_JQ")

        exists=$(printf '%s' "$gitea_hooks" | jq -r --arg u "$hook_url" '[.[]? | select(.config.url == $u) | .id] | first // empty')

        if [ -n "$exists" ] && [ "$overwrite" = true ]; then
            echo "     [WEBHOOK] Overwrite enabled. Deleting existing webhook -> $hook_url"
            http_req gitea DELETE "$gitea_url/$exists"
            if is_2xx "$RESP_CODE"; then inc "count_${scope}_webhooks_overwritten"; exists=""
            else inc "count_${scope}_webhooks_failed"; record_failure "Webhook Delete ($scope): $label -> $hook_url (HTTP $RESP_CODE)"; continue
            fi
        fi

        if [ -z "$exists" ]; then
            echo "     [WEBHOOK] Migrating webhook -> $hook_url (active=$hook_active)"
            payload=$(jq -n --arg url "$hook_url" --arg ct "$hook_ct" --argjson active "$hook_active" --argjson events "$hook_events" \
                '{type:"gitea", active:$active, events:$events, config:{url:$url, content_type:$ct}}')
            http_req gitea POST "$gitea_url" "$payload"
            if is_2xx "$RESP_CODE"; then inc "count_${scope}_webhooks_migrated"
            else inc "count_${scope}_webhooks_failed"; record_failure "Webhook Create ($scope): $label -> $hook_url (HTTP $RESP_CODE $(jmsg))"
            fi
        else
            inc "count_${scope}_webhooks_skipped"
        fi
    done < <(printf '%s\n' "$gh_hooks" | jq -c '.[]')
}
