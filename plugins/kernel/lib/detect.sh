# detect.sh -- decide whether a directory belongs to a Kernel (kernel.sh) project. POSIX sh, sourced.
# Needs lib/common.sh. Markers live in rules/markers.tsv (tier 1: one hit; tier 2: two different groups).
#
# kp_detect <dir>  sets:
#   KP_DET           1 detected / 0 not
#   KP_DET_TIER      1, 2 or 0
#   KP_DET_SUMMARY   short human text, e.g. "@onkernel/sdk ^0.127.0 (package.json)"
#   KP_DET_EVIDENCE  lines "tier<TAB>group<TAB>file<TAB>line<TAB>label"
#   KP_DET_ROOT      git toplevel (or the dir itself outside git)
#   KP_DET_CACHED    1 when answered from the cache
# Scan order: cache (HEAD + manifest mtimes) -> manifests/config files -> git grep (or grep -r) for
# the scope=all markers, stopping at the first tier-1 hit. $HOME and / are never scanned.

KP_MARKERS="${KP_MARKERS:-$KP_PLUGIN_ROOT/rules/markers.tsv}"

# kp_cfg_files <root> [find-args...]: manifests / CI / config files, depth <= 3
kp_cfg_files() {
  _kp_croot="$1"; shift
  find "$_kp_croot" -maxdepth "${KP_CFG_DEPTH:-3}" \( -name node_modules -o -name .git -o -name vendor -o -name dist -o -name target -o -name .venv \) -prune -o \
    -type f \( -name package.json -o -name package-lock.json -o -name npm-shrinkwrap.json -o -name pnpm-lock.yaml -o -name yarn.lock \
      -o -name bun.lock -o -name '.env*' -o -name .mcp.json -o -name Makefile -o -name 'Dockerfile*' -o -name 'docker-compose*' \
      -o -name '*.tf' -o -path '*/.github/workflows/*' \) "$@"
}

# kp_marker_union <all|scope-all>: alternation of marker EREs
kp_marker_union() {
  awk -F'\t' -v only="$1" '/^#/ || NF < 4 { next } only == "all" || $3 == "all" { printf "%s(%s)", sep, $4; sep = "|" }' "$KP_MARKERS"
}

# kp_marker_needles: literal needles of the scope=all markers, one per line
kp_marker_needles() {
  awk -F'\t' '/^#/ || NF < 6 || $3 != "all" { next } { n = split($6, a, ";"); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' "$KP_MARKERS"
}

# kp_classify <seedfile>: stdin = grep -n output ("file:line:text"); stdout = T1/T2 evidence lines.
kp_classify() {
  awk -F'\t' -v mk="$KP_MARKERS" -v seed="$1" '
    BEGIN {
      while ((getline l < mk) > 0) { if (l ~ /^#/ || l == "") continue; split(l, f, "\t"); n++; tier[n] = f[1]; grp[n] = f[2]; re[n] = f[4]; ex[n] = f[5] }
      while (seed != "" && (getline l < seed) > 0) { split(l, f, "\t"); if (f[1] == "T2" && !(f[2] in seen)) { seen[f[2]] = 1; ng++; ev[ng] = l } }
    }
    {
      line = $0
      if (!match(line, /:[0-9]+:/)) next
      file = substr(line, 1, RSTART - 1); ln = substr(line, RSTART + 1, RLENGTH - 2); text = substr(line, RSTART + RLENGTH)
      sub(/^\.\//, "", file)
      for (i = 1; i <= n; i++) {
        if (text !~ re[i]) continue
        if (ex[i] != "" && text ~ ex[i]) continue
        match(text, re[i]); m = substr(text, RSTART, RLENGTH)
        if (m ~ /kernel[[:space:]]/ && m !~ /^kernel/) sub(/^[^k]*/, "", m)
        sub(/^[^A-Za-z@"]+/, "", m); sub(/[[:space:]]+$/, "", m); if (length(m) > 60) m = substr(m, 1, 60)
        if (file ~ /(^|\/)package\.json$/ && match(text, /"@onkernel\/[a-z-]+"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
          v = substr(text, RSTART, RLENGTH); sub(/^[^:]*:[[:space:]]*"/, "", v); sub(/"$/, "", v); sub(/^"/, "", m); sub(/"$/, "", m); m = m " " v
        }
        rec = tier[i] "\t" grp[i] "\t" file "\t" ln "\t" m
        if (tier[i] == 1) { print "T1\t" grp[i] "\t" file "\t" ln "\t" m; done = 1; exit }
        if (!(grp[i] in seen)) { seen[grp[i]] = 1; ng++; ev[ng] = "T2\t" grp[i] "\t" file "\t" ln "\t" m }
      }
    }
    END { if (!done) for (i = 1; i <= ng; i++) print ev[i] }'
}

# kp_scan_all <root>: grep (fixed-string needles) for scope=all markers; kp_classify confirms with the ERE
kp_scan_all() {
  _kp_nl="$(kp_marker_needles)"; _kp_oifs="$IFS"; IFS='
'
  set -- "$1"; for _kp_n in $_kp_nl; do set -- "$@" -e "$_kp_n"; done
  IFS="$_kp_oifs"; _kp_sroot="$1"; shift
  if git -C "$_kp_sroot" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$_kp_sroot" grep -I -n -F --untracked --exclude-standard "$@" -- . \
      ':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/dist/**' ':(exclude,glob)**/target/**' \
      ':(exclude,glob)**/.venv/**' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/pnpm-lock.yaml' ':(exclude,glob)**/yarn.lock' \
      ':(exclude,glob)**/*.min.js' ':(exclude,glob)**/*.map' 2>/dev/null
  else
    ( cd "$_kp_sroot" && grep -r -I -n -F --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor --exclude-dir=dist \
        --exclude-dir=target --exclude-dir=.venv --exclude=package-lock.json --exclude=pnpm-lock.yaml --exclude=yarn.lock \
        --exclude='*.min.js' --exclude='*.map' "$@" . 2>/dev/null )
  fi
}

kp_detect() {
  KP_DET=0; KP_DET_TIER=0; KP_DET_SUMMARY=""; KP_DET_EVIDENCE=""; KP_DET_ROOT=""; KP_DET_CACHED=0
  _kp_dir="${1:-.}"
  [ -d "$_kp_dir" ] || return 0
  _kp_out="$(git -C "$_kp_dir" rev-parse --show-toplevel HEAD 2>/dev/null)"
  if [ -n "$_kp_out" ]; then
    _kp_nl='
'
    KP_DET_ROOT="${_kp_out%%"$_kp_nl"*}"; _kp_head="${_kp_out#*"$_kp_nl"}"; [ "$_kp_head" != "$_kp_out" ] || _kp_head="nohead"
  else
    KP_DET_ROOT="$_kp_dir"; _kp_head="nogit"
  fi
  case "$KP_DET_ROOT" in /|"${HOME:-/nonexistent-home}") return 0 ;; esac
  _kp_key="$KP_DET_ROOT"
  while :; do case "$_kp_key" in */*) _kp_key="${_kp_key%%/*}_${_kp_key#*/}" ;; *) break ;; esac; done
  _kp_cache="$(kp_state_root)/detect-$_kp_key"

  # 1. cache: same HEAD, no manifest (depth <= 2, plus .github/workflows) newer than the cache; negatives expire after a day
  if [ -f "$_kp_cache" ]; then
    { IFS= read -r _kp_ch; } < "$_kp_cache"
    if [ "$_kp_ch" = "$_kp_head" ] && [ -z "$(KP_CFG_DEPTH=2 kp_cfg_files "$KP_DET_ROOT" -newer "$_kp_cache" -print 2>/dev/null)" ]; then
      _kp_wf=""; [ -d "$KP_DET_ROOT/.github/workflows" ] && _kp_wf="$(find "$KP_DET_ROOT/.github/workflows" -maxdepth 1 -newer "$_kp_cache" 2>/dev/null)"
      { IFS= read -r _kp_ch; IFS= read -r KP_DET; IFS= read -r KP_DET_TIER; IFS= read -r KP_DET_SUMMARY
        KP_DET_EVIDENCE="$(cat)"; } < "$_kp_cache"
      if [ -z "$_kp_wf" ] && { [ "$KP_DET" = 1 ] || [ -z "$(find "$_kp_cache" -mtime +0 2>/dev/null)" ]; }; then
        KP_DET_CACHED=1
        return 0
      fi
      KP_DET=0; KP_DET_TIER=0; KP_DET_SUMMARY=""; KP_DET_EVIDENCE=""
    fi
  fi

  # 2-3. manifests and config files, 4. everything else; both feed the same classifier
  _kp_ua="$(kp_marker_union all)"
  [ -n "$_kp_ua" ] || return 0
  _kp_tmp="$(mktemp "${TMPDIR:-/tmp}/kp-det.XXXXXX")" || return 0
  ( cd "$KP_DET_ROOT" && kp_cfg_files . -exec grep -I -n -E -e "$_kp_ua" /dev/null {} + 2>/dev/null ) | kp_classify "" > "$_kp_tmp"
  if ! grep -q '^T1' "$_kp_tmp"; then
    kp_scan_all "$KP_DET_ROOT" | kp_classify "$_kp_tmp" > "$_kp_tmp.2"
    mv "$_kp_tmp.2" "$_kp_tmp"
  fi
  if grep -q '^T1' "$_kp_tmp"; then
    KP_DET=1; KP_DET_TIER=1; KP_DET_EVIDENCE="$(sed -n 1p "$_kp_tmp")"
    KP_DET_SUMMARY="$(printf '%s\n' "$KP_DET_EVIDENCE" | awk -F'\t' '{ printf "%s (%s)", $5, $3 }')"
  elif [ "$(grep -c '^T2' "$_kp_tmp")" -ge 2 ]; then
    KP_DET=1; KP_DET_TIER=2; KP_DET_EVIDENCE="$(grep '^T2' "$_kp_tmp")"
    KP_DET_SUMMARY="$(printf '%s\n' "$KP_DET_EVIDENCE" | awk -F'\t' 'NR <= 2 { printf "%s%s (%s)", (NR > 1 ? "; " : ""), $5, $3 }')"
  fi
  rm -f "$_kp_tmp" "$_kp_tmp.2"

  # cache write (best effort)
  mkdir -p "$(kp_state_root)" 2>/dev/null
  { printf '%s\n%s\n%s\n%s\n' "$_kp_head" "$KP_DET" "$KP_DET_TIER" "$KP_DET_SUMMARY"
    if [ -n "$KP_DET_EVIDENCE" ]; then printf '%s\n' "$KP_DET_EVIDENCE"; fi; } > "$_kp_cache.$$" 2>/dev/null
  mv "$_kp_cache.$$" "$_kp_cache" 2>/dev/null || rm -f "$_kp_cache.$$" 2>/dev/null
  return 0
}
