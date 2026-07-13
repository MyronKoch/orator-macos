#!/bin/bash
# kokoro-speak - System-wide TTS using local Kokoro server
# Usage: echo "text" | kokoro-speak
#        kokoro-speak "text to speak"
#
# Config via environment variables:
#   KOKORO_URL    - API endpoint (default: http://localhost:8880)
#   KOKORO_VOICE  - Voice ID (default: af_heart)
#   KOKORO_SPEED  - Playback speed (default: 1.0)
#   KOKORO_MODEL  - Model name (default: prince-canuma/Kokoro-82M)

set -uo pipefail

KOKORO_URL="${KOKORO_URL:-http://localhost:8880}"
KOKORO_VOICE="${KOKORO_VOICE:-af_heart}"
KOKORO_SPEED="${KOKORO_SPEED:-1.0}"
KOKORO_MODEL="${KOKORO_MODEL:-prince-canuma/Kokoro-82M}"
PID_FILE="/tmp/kokoro-speak.pid"

# Toggle: if already playing, stop and exit
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
  rm -f "$PID_FILE"
  exit 0
fi
rm -f "$PID_FILE"

# Read text from argument or stdin
if [ $# -gt 0 ]; then
  TEXT="$*"
else
  TEXT=$(cat)
fi

# Normalize text for TTS: collapse paragraph breaks and newlines into spaces
TEXT=$(printf '%s' "$TEXT" | tr '\r' '\n' | sed '/^$/d' | tr '\n' ' ' | sed 's/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

# Exit if empty
[ -z "$TEXT" ] && exit 0

# Check if Kokoro is running
if ! curl -s --connect-timeout 2 "$KOKORO_URL/v1/models" > /dev/null 2>&1; then
  osascript -e 'display notification "Kokoro server is not running" with title "Kokoro Speak" sound name "Basso"'
  exit 1
fi

# Generate speech
TMPFILE=$(mktemp /tmp/kokoro-speech-XXXXXX)

curl -s -X POST "$KOKORO_URL/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg model "$KOKORO_MODEL" \
    --arg input "$TEXT" \
    --arg voice "$KOKORO_VOICE" \
    --argjson speed "$KOKORO_SPEED" \
    '{model: $model, input: $input, voice: $voice, speed: $speed}')" \
  -o "$TMPFILE"

# Check if we got valid audio
if [ ! -s "$TMPFILE" ]; then
  osascript -e 'display notification "Failed to generate speech" with title "Kokoro Speak" sound name "Basso"'
  rm -f "$TMPFILE"
  exit 1
fi

# Play audio in background, save PID for stop capability
afplay "$TMPFILE" &
PLAY_PID=$!
echo $PLAY_PID > "$PID_FILE"

# Wait for playback to finish, then cleanup
wait $PLAY_PID 2>/dev/null
rm -f "$TMPFILE" "$PID_FILE"
