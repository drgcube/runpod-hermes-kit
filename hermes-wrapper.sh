# ============================================================================
# hermes-wrapper.sh — sourced by your ~/.zshrc or ~/.bashrc.
#
# Defines a hermes() shell function that boots the RunPod GPU on demand, runs
# the real Hermes CLI, and stops the pod on exit — so the GPU only bills while
# you're actually chatting.
#
# It DELEGATES the pod lifecycle to runpod-hermes.sh (up/down), so all the smart
# behaviour — resume, AUTO-MIGRATE to a fresh pod when a host is out of GPUs,
# model serving, health checks — lives in one place and applies here too.
#
# `runpod-hermes.sh install` wires this up and sets the two vars below.
# Works under both bash and zsh.
# ============================================================================

: "${RUNPOD_HERMES_CONF:=$HOME/.config/runpod-hermes/default.conf}"
: "${RUNPOD_HERMES_CLI:=$HOME/runpod-hermes-kit/runpod-hermes.sh}"

hermes() {
  # --- fast path: management subcommands don't need the GPU pod --------------
  case "${1:-}" in
    update|config|model|models|mcp|skills|version|doctor|help|--help|-h|--version|-v)
      command hermes "$@"; return $? ;;
  esac

  local cli="$RUNPOD_HERMES_CLI" conf="$RUNPOD_HERMES_CONF"
  if [ ! -f "$cli" ];  then echo "hermes(): kit CLI not found: $cli"  >&2; return 1; fi
  if [ ! -f "$conf" ]; then echo "hermes(): config not found: $conf" >&2; return 1; fi

  # Session id for ref-counting — the terminal's shell PID. `down` only stops the
  # pod when the LAST session exits, so closing one window won't kill another's.
  local sid="$$"

  # Stop the pod on EVERY exit path: normal return, Ctrl-C (INT), kill (TERM),
  # terminal close (HUP), AND a failed bring-up (which may have created a pod).
  # Armed BEFORE `up` so nothing can leak. `down` re-reads the conf, so it stops
  # the CURRENT pod even if `up` auto-migrated to a new one. It respects the
  # session count + KEEP_ALIVE (see runpod-hermes.sh).
  local _rph_done=0
  _rph_stop() { [ "$_rph_done" = 1 ] && return; _rph_done=1; RPH_SESSION="$sid" bash "$cli" -c "$conf" down >/dev/null 2>&1; }
  trap '_rph_stop' INT TERM HUP

  # Bring the pod up: resume it, or — if its host has no free GPU — auto-migrate
  # to a fresh pod on the same volume, then open the tunnel and start the model.
  # (Run via `bash` so a stripped exec bit on the CLI never matters.)
  if ! RPH_SESSION="$sid" bash "$cli" -c "$conf" up; then
    echo "hermes(): could not bring the pod up — cleaning up" >&2
    _rph_stop; trap - INT TERM HUP; return 1
  fi

  # --- run the real Hermes CLI ---------------------------------------------
  command hermes "$@"

  trap - INT TERM HUP
  _rph_stop
}
