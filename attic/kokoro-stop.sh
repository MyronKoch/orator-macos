#!/bin/bash
# kokoro-stop - Stop any running Kokoro speech playback
PID_FILE="/tmp/kokoro-speak.pid"
if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
  rm -f "$PID_FILE"
fi
