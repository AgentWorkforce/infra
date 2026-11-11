#!/usr/bin/env bash
# Read the producer to completion before matching, preserving its exit status.
# A quiet grep in a pipeline can close early and fail kubectl with SIGPIPE.
log_matches() { # grep-flags pattern command [args...]
  local flags=$1 pattern=$2 output
  shift 2
  output=$("$@") || return
  grep "$flags" -- "$pattern" <<<"$output" >/dev/null
}
