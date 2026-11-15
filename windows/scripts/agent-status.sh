#!/bin/zsh
# Sends a Claude agent state to MiniChroma on 127.0.0.1:47800.
# States: thinking, editing, done, needs_input, idle. Does nothing if MiniChroma is not running.
printf '{"type":"agent","status":"%s"}' "${1:-idle}" | nc -u -w1 127.0.0.1 47800 >/dev/null 2>&1 || true
exit 0
