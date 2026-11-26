# Sourced by run.sh.
# Rate-limit aware, token-safe, dry-run aware HTTP client.
#
# Reads globals: TMP_DIR, GH_HDR, GITEA_HDR, HDRS_FILE, BODY_FILE, ERR_FILE,
#                PAYLOAD_FILE, GITEA_URL, DRY_RUN, GH_MAX_WAIT.
# Uses: inc, is_2xx (from lib/utils.sh).
#
#   http_req <gh|gitea> <METHOD> <url> [json] [timeout]
#   sets RESP_CODE, RESP_BODY, RESP_HEADERS
#
#   paginate <gh|gitea> <url>
#   sets PAGED_JSON, PAGED_CODE, PAGED_ERR ; returns 1 on error

RESP_CODE=0; RESP_BODY=""; RESP_HEADERS=""

hdr_val() { grep -i "^$1:" "$HDRS_FILE" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}'; }
jmsg() { printf '%s' "$RESP_BODY" | jq -r 'if type=="object" then (.message // empty) else empty end' 2>/dev/null | head -c 200; }

http_req() {
    local target="$1" method="$2" url="$3" data="${4:-}" tmo="${5:-120}"
    local hdr code attempt=0 remaining reset retry wait now
    if [ "$target" = gh ]; then hdr="$GH_HDR"; else hdr="$GITEA_HDR"; fi

    if [ "$target" = gitea ] && [ "$method" != GET ] && [ "$DRY_RUN" = true ]; then
        echo "     [DRY-RUN] $method ${url#"$GITEA_URL"}"
        if [ "$method" = DELETE ]; then RESP_CODE=204; else RESP_CODE=201; fi
        RESP_BODY='{"id":0}'; RESP_HEADERS=""
        return 0
    fi

    while :; do
        attempt=$((attempt + 1))
        if [ "$target" = gh ]; then inc count_gh_calls; fi
        : > "$HDRS_FILE"; : > "$BODY_FILE"
        local -a args=(-sS -X "$method" -H "@$hdr" -D "$HDRS_FILE" -o "$BODY_FILE" -w '%{http_code}' --max-time "$tmo")
        if [ -n "$data" ]; then
            printf '%s' "$data" > "$PAYLOAD_FILE"
            args+=(--data-binary "@$PAYLOAD_FILE")
        fi
        code=$(curl "${args[@]}" "$url" 2>"$ERR_FILE")
        [ -z "$code" ] && code=000

        # transport failure: retry idempotent requests only
        if [ "$code" = 000 ] && [ "$method" = GET ] && [ "$attempt" -le 3 ]; then
            sleep $((attempt * 3)); continue
        fi

        if [ "$target" = gh ]; then
            remaining=$(hdr_val x-ratelimit-remaining)
            reset=$(hdr_val x-ratelimit-reset)
            retry=$(hdr_val retry-after)
            now=$(date +%s)
            if [ "$code" = 403 ] || [ "$code" = 429 ]; then
                wait=0
                if [ -n "$retry" ]; then wait="$retry"
                elif [ "$remaining" = "0" ] && [ -n "$reset" ]; then wait=$((reset - now + 2))
                elif grep -qi 'rate limit' "$BODY_FILE" 2>/dev/null; then wait=60
                fi
                if [ "$wait" -gt 0 ] 2>/dev/null && [ "$attempt" -le 5 ]; then
                    [ "$wait" -gt "$GH_MAX_WAIT" ] && wait="$GH_MAX_WAIT"
                    echo "     [RATE LIMIT] GitHub limit hit (HTTP $code). Sleeping ${wait}s..."
                    sleep "$wait"; continue
                fi
            elif [ -n "$remaining" ] && [ -n "$reset" ] && [ "$remaining" -le 2 ] 2>/dev/null; then
                wait=$((reset - now + 2))
                if [ "$wait" -gt 0 ]; then
                    [ "$wait" -gt "$GH_MAX_WAIT" ] && wait="$GH_MAX_WAIT"
                    echo "     [RATE LIMIT] GitHub quota nearly exhausted. Sleeping ${wait}s..."
                    sleep "$wait"
                fi
            fi
        fi
        break
    done

    RESP_CODE="$code"
    RESP_BODY=$(cat "$BODY_FILE")
    RESP_HEADERS=$(cat "$HDRS_FILE")
    if [ "$code" = 000 ]; then RESP_BODY="{\"message\":\"transport error: $(head -c 150 "$ERR_FILE" | tr '"\n' "' ")\"}"; fi
    return 0
}

PAGED_JSON='[]'; PAGED_CODE=0; PAGED_ERR=""
paginate() {
    local target="$1" url="$2" page=1 size param sep n
    if [ "$target" = gh ]; then size=100; param=per_page; else size=50; param=limit; fi
    case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
    PAGED_JSON='[]'; PAGED_ERR=""; PAGED_CODE=0
    while [ "$page" -le 500 ]; do
        http_req "$target" GET "${url}${sep}${param}=${size}&page=${page}"
        if ! is_2xx "$RESP_CODE"; then
            PAGED_CODE="$RESP_CODE"; PAGED_ERR="HTTP $RESP_CODE $(jmsg)"; return 1
        fi
        if ! printf '%s' "$RESP_BODY" | jq -e 'type=="array"' >/dev/null 2>&1; then
            PAGED_CODE="$RESP_CODE"; PAGED_ERR="unexpected (non-array) response"; return 1
        fi
        n=$(printf '%s' "$RESP_BODY" | jq 'length')
        [ "$n" -eq 0 ] && break
        PAGED_JSON=$(printf '%s\n%s' "$PAGED_JSON" "$RESP_BODY" | jq -c -s 'add')
        # GitHub's requested per_page=100 is the documented upper bound for the
        # endpoints used here, so a short page ends pagination. Gitea can clamp
        # limit=50 to its configured api.MAX_RESPONSE_ITEMS; a short Gitea page
        # is therefore NOT proof that it was the last page. Keep paging until
        # Gitea returns an empty array.
        if [ "$target" = gh ] && [ "$n" -lt "$size" ]; then break; fi
        page=$((page + 1))
    done
    if [ "$page" -gt 500 ]; then
        PAGED_CODE=0; PAGED_ERR="pagination exceeded the 500-page safety limit (results may be incomplete)"
        return 1
    fi
    return 0
}
