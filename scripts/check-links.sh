#!/usr/bin/env bash
# check-links.sh -- every https URL in plugin files and docs must answer < 400 (HEAD, then GET fallback).
# Skips anchors, localhost, example domains and URLs containing '***' or '<'.
set -u
cd "$(git rev-parse --show-toplevel)"
fail=0
urls="$(git ls-files -co --exclude-standard 'plugins/**' README.md THIRD_PARTY_NOTICES.md verified-facts.md DECISIONS.md 2>/dev/null | grep -E '\.(md|json|tsv|txt|sh|ts)$' | xargs grep -h -o -E 'https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' 2>/dev/null | sed -E 's/[.,;:)>"'"'"'`*]+$//; s/#.*$//' | grep -v -E '\*\*\*|<|localhost|example\.com|\.example|\.invalid|^https://\$|yourdomain\.com|^https://(api|mcp)\.onkernel\.com|herokuapp|toscrape|httpbin|sannysoft|recaptcha|yigitkonur/plugin-kernel-sh' | sort -u)"
n=0
while IFS= read -r u; do
  [ -z "$u" ] && continue
  n=$((n+1))
  code="$(curl -s -o /dev/null -L -m 20 -w '%{http_code}' -I "$u" 2>/dev/null)"
  case "$code" in 2*|3*) ;; *) code="$(curl -s -o /dev/null -L -m 20 -w '%{http_code}' "$u" 2>/dev/null)";; esac
  case "$code" in 2*|3*) ;; *) echo "check-links: $code $u" >&2; fail=1;; esac
done <<< "$urls"
echo "check-links: checked $n URLs"
exit $fail
