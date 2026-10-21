# rules-check.awk -- H3 core. Variables: rl (stale-api.tsv) mk (markers.tsv) tg (target file on disk)
# skipk019 (1 = target is a gitignored .env: key literal is fine there). stdin = the NEW text of the tool input.
# A rule is reported when more lines of the NEW text match its regex than lines of the OLD text (the text the edit
# replaced), AND a line of the file on disk matches, and the file carries at least one detection marker (tier 1 or 2).
# stdin = the new text, then a line SEP, then the old text (absent = nothing replaced). So a legacy line that an Edit
# only repeats as context is silent. Output: id<TAB>severity<TAB>line<TAB>message<TAB>replacement<TAB>url
BEGIN {
  FS = "\t"
  tg = ENVIRON["KP_TG"]
  while ((getline l < rl) > 0) { if (l ~ /^#/ || l == "") continue; split(l, f, "\t"); n++; id[n] = f[1]; sev[n] = f[2]; re[n] = f[3]; msg[n] = f[4]; rep[n] = f[5]; url[n] = f[7] }
  while ((getline l < mk) > 0) { if (l ~ /^#/ || l == "") continue; split(l, f, "\t"); m++; mre[m] = f[4]; mex[m] = f[5] }
}
BEGIN { SEP = "\001KP-OLD\001" }
$0 == SEP { inold = 1; next }
{ for (r = 1; r <= n; r++) if ($0 ~ re[r]) { if (inold) oldn[r]++; else newn[r]++ } }
END {
  any = 0; for (r = 1; r <= n; r++) { hit[r] = (newn[r] > oldn[r]); if (hit[r]) any = 1 }
  if (!any) exit
  ln = 0
  while ((getline l < tg) > 0) {
    ln++
    if (!gate) for (j = 1; j <= m; j++) if (l ~ mre[j] && (mex[j] == "" || l !~ mex[j])) { gate = 1; break }
    for (r = 1; r <= n; r++) if (hit[r] && !first[r] && l ~ re[r]) first[r] = ln
  }
  if (!gate) exit
  for (r = 1; r <= n; r++) {
    if (!first[r]) continue
    if (id[r] == "K019" && skipk019 == 1) continue
    print id[r] "\t" sev[r] "\t" first[r] "\t" msg[r] "\t" rep[r] "\t" url[r]
  }
}
