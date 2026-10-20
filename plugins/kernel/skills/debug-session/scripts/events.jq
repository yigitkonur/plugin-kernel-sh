# events.jq -- the debug-session projection of a telemetry events.json: one TSV row per interesting event.
# Free text and URLs are redacted: bearer/basic values, secret-looking key=value and key: value pairs, URL userinfo,
# query strings and fragments, and long opaque path segments. Redaction is best effort: never paste a row elsewhere.
def clean:
  if type != "string" then . else
    gsub("(?<k>(?i:bearer|basic)\\s+)[^\\s\"']+"; "\(.k)***")
    | gsub("(?<k>(?i:authorization|password|passwd|secret|token|access_token|id_token|refresh_token|api[_-]?key|apikey|jwt|sig|signature|cookie|session)[\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;&}]+"; "\(.k)***")
    | gsub("(?<k>//)[^/\\s@]*@"; "\(.k)***@")
    | gsub("[?#][^\\s\"']*"; "?***")
    | gsub("/[A-Za-z0-9_-]{24,}"; "/***")
    | gsub("sk_[A-Za-z0-9_.-]+"; "sk_***")
  end;
.events[]
| select(.event.type=="console_error"
    or (.event.type=="network_loading_failed" and .event.data.target_type=="page")
    or (.event.type=="network_response" and .event.data.status>=400)
    or (.event.type|IN("page_crashed","system_oom_kill","service_crashed","proxy_error","monitor_disconnected","monitor_reconnected","cdp_disconnect")))
| [.seq, (.event.ts/1000000|floor|todate), .event.type,
   ((.event.data.status // (.event.data.error_text|clean) // ((.event.data.text // "")|clean|.[0:120]))),
   ((.event.data.url // "")|clean)] | @tsv
