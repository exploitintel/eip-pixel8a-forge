#!/system/bin/sh
# Merge KEY=VALUE lines arriving on stdin into both v4 env files. Values never
# appear in argv, in the process list, or in this script's output; only key
# names and lengths are reported back.
UI=/data/eip-cve/config/eip-cve-ui.env
CHAT=/data/eip-cve/config/eip-cve-agent-chat.env

[ -f "$UI" ] && [ -f "$CHAT" ] || { echo "merge-env: env files missing" >&2; exit 1; }

IN=$(mktemp /data/eip-cve/.mergeenv.XXXXXX) || exit 1
chmod 600 "$IN"
cat > "$IN"

n=0
while IFS= read -r line; do
  case "$line" in
    [A-Z]*=*) ;;
    *) continue ;;
  esac
  key=${line%%=*}
  val=${line#*=}
  [ -n "$val" ] || continue
  for f in "$UI" "$CHAT"; do
    tmp="$f.tmp.$$"
    : > "$tmp"; chmod 600 "$tmp"
    grep -v "^$key=" "$f" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    chown 2000:2000 "$tmp"
    mv -f "$tmp" "$f"
  done
  n=$((n+1))
  printf 'merged %s (%s chars)\n' "$key" "$(printf '%s' "$val" | wc -c | tr -d ' ')"
done < "$IN"

rm -f "$IN"
chmod 600 "$UI" "$CHAT"; chown 2000:2000 "$UI" "$CHAT"
echo "merged $n keys into both env files"
