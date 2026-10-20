# rules-lint.awk -- lint core. Variables: rl (stale-api.tsv). Input: files as arguments.
# Output: file<TAB>line<TAB>id<TAB>severity<TAB>text<TAB>message<TAB>replacement<TAB>url   (text = trimmed to 120 chars)
BEGIN {
  FS = "\t"
  while ((getline l < rl) > 0) { if (l ~ /^#/ || l == "") continue; split(l, f, "\t"); n++; id[n] = f[1]; sev[n] = f[2]; re[n] = f[3]; msg[n] = f[4]; rep[n] = f[5]; url[n] = f[7] }
}
{
  for (r = 1; r <= n; r++) if ($0 ~ re[r]) {
    t = $0; gsub(/\t/, " ", t); sub(/^[[:space:]]+/, "", t); if (length(t) > 120) t = substr(t, 1, 120)
    gsub(/sk_[0-9a-fA-F]+(-[0-9a-fA-F]+)+\.[A-Za-z0-9_-]+/, "sk_***", t)   # no rule echoes a key that shares the line
    if (id[r] == "K019") t = "[key literal masked]"
    print FILENAME "\t" FNR "\t" id[r] "\t" sev[r] "\t" t "\t" msg[r] "\t" rep[r] "\t" url[r]
  }
}
