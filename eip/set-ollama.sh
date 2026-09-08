#!/system/bin/sh
# Point the v4 model lane at the Ollama API over https instead of the local
# daemon service that bootstrap.sh assumes. Run once after bootstrap.
# usage: set-ollama.sh [https-base-url]
URL=${1:-https://ollama.com}
UI=/data/eip-cve/config/eip-cve-ui.env
CHAT=/data/eip-cve/config/eip-cve-agent-chat.env

set -e
[ -f "$UI" ] || { echo "set-ollama: $UI is missing; run bootstrap first" >&2; exit 1; }

# The UI lane: the daemon URL the listing, health probe and launch path use.
sed -i "s|^EIP_CVE_OLLAMA_URL=.*|EIP_CVE_OLLAMA_URL=$URL|" "$UI"
grep -q '^OLLAMA_API_KEY=' "$UI" || printf 'OLLAMA_API_KEY=\n' >> "$UI"

# The Agent broker lane: its own daemon URL knob, plus the token it renders
# into the managed models.toml.
grep -q '^EIP_CVE_CHAT_OLLAMA_URL=' "$CHAT" \
  && sed -i "s|^EIP_CVE_CHAT_OLLAMA_URL=.*|EIP_CVE_CHAT_OLLAMA_URL=$URL|" "$CHAT" \
  || printf 'EIP_CVE_CHAT_OLLAMA_URL=%s\n' "$URL" >> "$CHAT"
grep -q '^OLLAMA_API_KEY=' "$CHAT" || printf 'OLLAMA_API_KEY=\n' >> "$CHAT"

chown 2000:2000 "$UI" "$CHAT"
chmod 600 "$UI" "$CHAT"

echo "ollama endpoint set to $URL"
grep -E '^(EIP_CVE_OLLAMA_URL|EIP_CVE_CHAT_OLLAMA_URL)=' "$UI" "$CHAT"
