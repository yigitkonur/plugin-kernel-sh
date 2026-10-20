# events.jq -- the debug-session projection of a telemetry events.json: one TSV row per interesting event.
# Free text and URLs are redacted: bearer/basic values, whole Cookie / Set-Cookie lines, secret-looking key=value and
# key: value pairs (the key may carry a prefix or suffix), bare JWTs, URL userinfo, query strings and fragments, and
# long opaque path segments. Redaction is best effort: never paste a row elsewhere.
def clean:
  if type != "string" then . else
    gsub("(?<k>(?i:bearer|basic)\\s+)[^\\s\"']+"; "\(.k)***")
    | gsub("(?<k>(?i:(set-)?cookie)[\"']?\\s*[:=]\\s*[\"']?)[^\\n\"']*"; "\(.k)***")
    | gsub("(?<k>[A-Za-z0-9_.-]{0,40}(?i:authorization|auth|password|passwd|secret|token|api[_-]?key|apikey|private[_-]?key|jwt|signature|credential|session)[A-Za-z0-9_.-]{0,40}[\"']?\\s*[:=]\\s*[\"']?)[^\\s\"',;&}]+"; "\(.k)***")
    | gsub("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]*)?"; "***jwt***")
    | gsub("(?<k>//)[^/\\s@]*@"; "\(.k)***@")
    | gsub("[?#][^\\s\"']*"; "?***")
    | gsub("/[A-Za-z0-9_-]{24,}"; "/***")
    | gsub("sk_[A-Za-z0-9_.-]+"; "sk_***")
  end;
.events[]
| select(.event.type=="console_error"
    or (.event.type=="network_loading_failed" and .event.data.target_type=="page")
    or (.event.type=="network_response" and .event.data.status>=400)
    or (.event.type|IN("page_crashed","system_oom_kill","service_crashed","proxy_error","monitor_disconnected","monitor_reconnected","cdp_connect","cdp_disconnect")))
| [.seq, (.event.ts/1000000|floor|todate), .event.type,
   ((.event.data.status // (.event.data.error_text|clean) // ((.event.data.text // "")|clean|.[0:120]))),
   ((.event.data.url // "")|clean)] | @tsv
