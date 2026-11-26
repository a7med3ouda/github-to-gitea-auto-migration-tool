# Sourced by run.sh.
# Deploy key migration (public keys only; private halves never leave GitHub).
#
# Uses: paginate, http_req, inc, warn, record_failure, is_2xx, jmsg.
# Reads globals: GITEA_URL, DRY_RUN, OVERWRITE_DEPLOY_KEYS.

# migrate_keys <github keys url> <gitea keys url> <label>
migrate_keys() {
    local gh_url="$1" gitea_url="$2" label="$3"
    local gh_keys gitea_keys key_obj key_title key_pub key_norm key_ro exists payload

    if ! paginate gh "$gh_url"; then
        if [ "$PAGED_CODE" = 403 ] || [ "$PAGED_CODE" = 404 ]; then
            warn "Deploy keys of $label not readable (HTTP $PAGED_CODE); skipped."
        else
            inc count_keys_failed; record_failure "Deploy Key List: $label ($PAGED_ERR)"
        fi
        return
    fi
    gh_keys="$PAGED_JSON"
    [ "$(printf '%s' "$gh_keys" | jq 'length')" -eq 0 ] && return

    if ! paginate gitea "$gitea_url"; then
        if [ "$DRY_RUN" = true ]; then PAGED_JSON='[]'
        else inc count_keys_failed; record_failure "Deploy Key List on Gitea: $label ($PAGED_ERR)"; return
        fi
    fi
    gitea_keys="$PAGED_JSON"

    while IFS= read -r key_obj; do
        key_title=$(printf '%s' "$key_obj" | jq -r '.title')
        key_pub=$(printf '%s' "$key_obj" | jq -r '.key')
        key_norm=$(printf '%s' "$key_pub" | awk '{print $1" "$2}')
        key_ro=$(printf '%s' "$key_obj" | jq -r 'if .read_only == null then true else .read_only end')

        exists=$(printf '%s' "$gitea_keys" | jq -r --arg k "$key_norm" \
            '[.[]? | select(((.key // "") | split(" ") | .[0:2] | join(" ")) == $k) | .id] | first // empty')

        if [ -n "$exists" ] && [ "$OVERWRITE_DEPLOY_KEYS" = true ]; then
            echo "     [DEPLOY KEY] Overwrite enabled. Deleting existing key: $key_title"
            http_req gitea DELETE "$gitea_url/$exists"
            if is_2xx "$RESP_CODE"; then inc count_keys_overwritten; exists=""
            else inc count_keys_failed; record_failure "Deploy Key Delete: $label -> $key_title (HTTP $RESP_CODE)"; continue
            fi
        fi

        if [ -z "$exists" ]; then
            echo "     [DEPLOY KEY] Migrating key: $key_title (read_only=$key_ro)"
            payload=$(jq -n --arg t "$key_title" --arg k "$key_pub" --argjson ro "$key_ro" '{title:$t, key:$k, read_only:$ro}')
            http_req gitea POST "$gitea_url" "$payload"
            if is_2xx "$RESP_CODE"; then inc count_keys_migrated
            else inc count_keys_failed; record_failure "Deploy Key Create: $label -> $key_title (HTTP $RESP_CODE $(jmsg))"
            fi
        else
            inc count_keys_skipped
        fi
    done < <(printf '%s\n' "$gh_keys" | jq -c '.[]')
}
