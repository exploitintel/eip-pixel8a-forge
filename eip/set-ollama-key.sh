#!/system/bin/sh
# Write the Ollama API token into both v4 env files. The token arrives on
# stdin, never as an argument, so it stays out of argv, the process list and
# shell history on both machines. Nothing echoes the value back.
UI=/data/eip-cve/config/eip-cve-ui.env
CHAT=/data/eip-cve/config/eip-cve-agent-chat.env

set -e
[ -f "$UI" ] && [ -f "$CHAT" ] || { echo "set-ollama-key: env files missing; run bootstrap first" >&2; exit 1; }

KEY=$(cat)
[ -n "$KEY" ] || { echo "set-ollama-key: empty token on stdin" >&2; exit 1; }
case "$KEY" in
  *[!A-Za-z0-9._-]*) echo "set-ollama-key: token has characters outside [A-Za-z0-9._-]" >&2; exit 1 ;;
esac

for f in "$UI" "$CHAT"; do
  # Rewrite through a 0600 temp in the same directory, so the token is never
  # briefly world-readable and never passed on a command line.
  tmp="$f.tmp.$$"
  : > "$tmp"
  chmod 600 "$tmp"
  grep -v '^OLLAMA_API_KEY=' "$f" > "$tmp" || true
  printf 'OLLAMA_API_KEY=%s\n' "$KEY" >> "$tmp"
  chown 2000:2000 "$tmp"
  mv -f "$tmp" "$f"
done

echo "token written to both env files"
for f in "$UI" "$CHAT"; do
  printf '%s: OLLAMA_API_KEY set, %s characters\n' "$f" "$(grep '^OLLAMA_API_KEY=' "$f" | cut -d= -f2- | wc -c | tr -d ' ')"
done
ls -l "$UI" "$CHAT"
