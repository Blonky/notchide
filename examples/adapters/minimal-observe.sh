#!/bin/sh
# minimal-observe.sh — a ~40-line AAP v1 reference adapter (observe-only).
#
# It connects to the notchide agent socket, performs the AAP handshake with
# capabilities ["observe"], emits a `started` and a `finished` AgentEvent for a
# fake session, and exits. Because it is observe-only it never gates and never
# waits for a decision — it is pure fan-in. See ../../docs/PROTOCOL.md.
#
# Wire facts this script relies on (all from docs/PROTOCOL.md):
#   * Transport is a Unix-domain stream socket (we use `nc -U`).
#   * Framing is NDJSON: one JSON object per line, '\n'-terminated.
#   * The FIRST line MUST be the handshake; every later line is an envelope.
#   * An envelope needs all three of: id, event, wantsDecision.
#   * observe-only => wantsDecision is always false; no decision comes back.
#
# Requirements: a POSIX shell, `nc` with Unix-socket support (`-U`, ships with
# macOS), `uuidgen`, and `date`. Run notchide (which owns the socket) first.
set -eu

# Resolve the socket path: honor NOTCHIDE_SOCKET_PATH, else the canonical path.
SOCKET="${NOTCHIDE_SOCKET_PATH:-$HOME/Library/Application Support/notchide/agent.sock}"

# A stable identity for this adapter, and a fake session to report on.
PROVIDER_ID="com.example.observe"
SESSION_ID="example-$(uuidgen)"
CWD="$(pwd)"
NOW="$(date +%s)"

if [ ! -S "$SOCKET" ]; then
  echo "no notchide socket at: $SOCKET" >&2
  echo "start the notchide app first (it owns the socket)." >&2
  exit 1
fi

# Build the three NDJSON frames. Values here contain no characters needing JSON
# escaping; a real adapter should JSON-encode dynamic strings properly.
HANDSHAKE="{\"aap\":\"1\",\"providerID\":\"$PROVIDER_ID\",\"capabilities\":[\"observe\"]}"
STARTED="{\"id\":\"$(uuidgen)\",\"wantsDecision\":false,\"event\":{\"providerID\":\"$PROVIDER_ID\",\"agentSessionID\":\"$SESSION_ID\",\"cwd\":\"$CWD\",\"kind\":\"started\",\"title\":\"example task\",\"payload\":{},\"at\":$NOW}}"
FINISHED="{\"id\":\"$(uuidgen)\",\"wantsDecision\":false,\"event\":{\"providerID\":\"$PROVIDER_ID\",\"agentSessionID\":\"$SESSION_ID\",\"cwd\":\"$CWD\",\"kind\":\"finished\",\"title\":\"example task\",\"payload\":{},\"at\":$(date +%s)}}"

# Send handshake, then both envelopes, on one connection. `printf` writes each
# frame on its own '\n'-terminated line; `nc -U` streams them to the socket and
# closes when stdin ends. We ask for no decision, so there is nothing to read.
printf '%s\n%s\n%s\n' "$HANDSHAKE" "$STARTED" "$FINISHED" | nc -U "$SOCKET"

echo "sent started + finished for session $SESSION_ID (provider $PROVIDER_ID)" >&2
