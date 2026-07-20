#!/usr/bin/env bash
# ============================================================================
# runpod-hermes.sh — set up & operate a RunPod GPU pod running llama.cpp,
#                    driven on-demand by the Hermes Agent CLI.
#
# Reproducible playbook for the setup documented in GUIDE.md. Everything is
# parameterised via a .conf file (see runpod-hermes.conf.example).
#
#   ./runpod-hermes.sh [-c CONF] <command> [args]
#
# Commands:
#   doctor        Check prerequisites, API access, and key/config health
#   fix-key       Set the pod's PUBLIC_KEY env to your real public key   <-- THE fix
#   create        Create a fresh pod on NETWORK_VOLUME_ID + write POD_ID to the conf
#   cycle         stop -> start the pod to trigger a fresh key injection, then verify
#   verify-key    SSH in and confirm authorized_keys contains your key
#   bootstrap     On the pod: build llama.cpp + download the model (one-time, slow)
#   config        Point the local Hermes config.yaml at the local server (backs up first)
#   install       Wire the hermes() wrapper into your shell rc
#   ensure        Resume pod, or AUTO-MIGRATE to a fresh pod on the volume if no GPU capacity
#   up            ensure + open tunnel + start model server (leaves it running)
#   down          Stop the pod IF this is the last hermes session (else leave it up)
#   stop          Force-stop the pod now, regardless of sessions/keep-alive
#   serve         (pod running) ensure the model server is up + healthy
#   status        Show pod state + server health + active sessions + keep-alive
#   watchdog      One idle-check: force-stop the pod if GPU idle >= IDLE_MINUTES (schedule via cron)
#   test          up -> one-shot through Hermes -> down   (add --keep to stay up)
#
# AUTO-MIGRATE: when a resume fails because the pod's host has no free GPU, the
# kit creates a fresh pod on the SAME network volume (model+build already there),
# repoints the conf, drops the old pod, and continues — capacity misses become
# invisible. Controlled by AUTO_MIGRATE / MIGRATE_TERMINATE_OLD / NETWORK_VOLUME_ID.
#
# MULTI-SESSION: several `hermes` windows share ONE pod. Each registers a session
# id ($RPH_SESSION); `down` only stops the pod when the LAST session exits (dead
# sessions auto-pruned). So closing one window won't kill another's pod.
#
# KEEP_ALIVE=1: never auto-stop on exit — the pod stays RUNNING (billing) until
# you `stop` it. Use in a heavy session so a tight GPU pool can't lock you out on
# the next resume. Reliability-vs-cost tradeoff (see GUIDE "Cost, capacity...").
#
# The RunPod API key is never printed. Gotchas from the field are enforced
# throughout — see the NOTE comments.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- pretty output (all to stderr, so functions can return data on stdout) --
_c()   { printf '%s\n' "$*"; }
log()  { printf '\033[1;36m[runpod-hermes]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- config ----------------------------------------------------------------
CONF=""
if [ "${1:-}" = "-c" ]; then CONF="${2:-}"; shift 2; fi
CONF="${CONF:-${RUNPOD_HERMES_CONF:-$SCRIPT_DIR/runpod-hermes.conf}}"
_ENV_API="${RUNPOD_API_KEY:-}"          # capture before conf can blank it out
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  source "$CONF"
else
  warn "config not found: $CONF  (copy runpod-hermes.conf.example)"
fi
# A conf with RUNPOD_API_KEY="" must not clobber an exported env key.
RUNPOD_API_KEY="${RUNPOD_API_KEY:-$_ENV_API}"

# Defaults for anything the conf didn't set (keeps commands from tripping on -u).
: "${RUNPOD_API_KEY:=${RUNPOD_API_KEY:-}}"
: "${POD_ID:=}"
: "${SSH_KEY:=$HOME/.ssh/id_ed25519}"
: "${VOLUME_PATH:=/workspace}"
: "${LLAMA_DIR:=$VOLUME_PATH/llama.cpp}"
: "${MODEL_DIR:=$VOLUME_PATH/models/my-model}"
: "${MODEL_FILE:=model.gguf}"
: "${HF_REPO:=}"
: "${HF_FILE:=$MODEL_FILE}"
: "${LLAMA_PORT:=8000}"
: "${LLAMA_CTX:=131072}"
: "${LLAMA_NGL:=999}"
: "${API_SECRET:=change-me}"
: "${MODEL_ALIAS:=local-model}"
: "${HERMES_CONFIG:=$HOME/.hermes/config.yaml}"
: "${LOCAL_PORT:=8000}"
: "${SHELL_RC:=$HOME/.zshrc}"
# Pod creation / auto-migration (used by `create` and by auto-migrate on a
# capacity failure). These make standing up a NEW pod fully reproducible.
: "${NETWORK_VOLUME_ID:=}"                 # existing volume with the model+build
: "${POD_IMAGE:=runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404}"
: "${GPU_TYPE_IDS:=NVIDIA A100-SXM4-80GB,NVIDIA A100 80GB PCIe}"  # comma list; first available wins
: "${CONTAINER_DISK_GB:=30}"
: "${POD_PORTS:=22/tcp,8888/http}"
: "${CLOUD_TYPE:=SECURE}"
: "${POD_NAME:=hermes-local}"
: "${JUPYTER_PASSWORD:=}"
: "${AUTO_MIGRATE:=1}"                      # on capacity failure, create a fresh pod on the volume
: "${MIGRATE_TERMINATE_OLD:=1}"            # delete the old (unstartable) pod after a successful migrate
# KEEP_ALIVE=1: never auto-stop the pod on hermes exit — it stays RUNNING (and
# billing) until you stop it manually (`down --force` / `stop`). Use during a
# heavy session so a tight GPU pool can't lock you out on the next resume.
: "${KEEP_ALIVE:=0}"
# Watchdog: stop the pod after this many minutes of GPU idleness (safety net for
# a forgotten/kept-alive pod). Used by `watchdog`; schedule it via cron/launchd.
: "${IDLE_MINUTES:=20}"

STATE_FILE="${TMPDIR:-/tmp}/runpod-hermes-${POD_ID:-none}.endpoint"

# ---- session ref-counting --------------------------------------------------
# So multiple `hermes` windows share ONE pod safely: each session registers its
# id (the shell PID, passed as $RPH_SESSION by the wrapper); the pod is only
# stopped when the LAST session exits. Keyed by conf (stable across migrates).
# Dead sessions are auto-pruned (kill -0), so a crashed window can't pin the pod.
sessions_file() { printf '%s/runpod-hermes-%s.sessions' "${TMPDIR:-/tmp}" "$(basename "$CONF" | tr -c 'A-Za-z0-9' '_')"; }
session_add()   { local f; f=$(sessions_file); grep -qxF "$1" "$f" 2>/dev/null || printf '%s\n' "$1" >> "$f"; }
session_clear() { rm -f "$(sessions_file)"; }
# Remove $1, prune dead pids, rewrite the file; return 0 if any LIVE session remains.
session_prune_and_any() {
  local f live="" pid; f=$(sessions_file); [ -f "$f" ] || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "${1:-}" ] && continue                 # drop the exiting session
    kill -0 "$pid" 2>/dev/null && live="$live$pid"$'\n' # keep only live ones
  done < "$f"
  printf '%s' "$live" > "$f"
  [ -n "$live" ]
}
READY_IP=""; READY_PORT=""     # set by wait_ready; consumed by cmd_up/cmd_ensure

# NOTE: host key changes on every new pod container, so pin nothing and never
# read a stale known_hosts entry. BatchMode so we fail fast instead of prompting.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=15)

# ---- low-level helpers -----------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need_cfg() {
  [ -n "$RUNPOD_API_KEY" ] || die "RUNPOD_API_KEY not set (conf or env)"
  [ -n "$POD_ID" ]         || die "POD_ID not set in $CONF"
}

# Non-interactive SSH (BatchMode) needs the key to be EITHER passphrase-free OR
# loaded in this shell's ssh-agent. A passphrase-protected key that isn't in the
# agent will silently fail every SSH attempt — so we check up front and fail with
# actionable guidance instead of hanging in wait_ready for minutes.
ssh_key_usable() {
  [ -f "$SSH_KEY" ] || return 1
  ssh-keygen -y -f "$SSH_KEY" -P "" >/dev/null 2>&1 && return 0   # no passphrase
  local fp; fp=$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')
  [ -n "$fp" ] && ssh-add -l 2>/dev/null | grep -qF "$fp"          # loaded in agent
}
require_ssh_key() {
  ssh_key_usable || die "SSH key $SSH_KEY is passphrase-protected and NOT loaded in ssh-agent — non-interactive SSH will fail (and hang). Load it once:  ssh-add --apple-use-keychain $SSH_KEY   then retry."
}

graphql() { # $1 = JSON body
  curl -sS -X POST https://api.runpod.io/graphql \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" \
    -d "$1"
}
rest_get() {
  curl -sS -H "Authorization: Bearer $RUNPOD_API_KEY" \
    "https://rest.runpod.io/v1/pods/$POD_ID"
}

# Resume the pod. Fails fast with the API's own message, EXCEPT transient
# GPU-capacity errors ("not enough free GPUs on the host machine"), which it
# retries: set RESUME_RETRIES (default 1) and RESUME_WAIT seconds (default 120).
#   e.g.  RESUME_RETRIES=10 RESUME_WAIT=120 ./runpod-hermes.sh ... up
resume_pod() {
  local resp err i tries="${RESUME_RETRIES:-1}" wait="${RESUME_WAIT:-120}"
  for ((i=1; i<=tries; i++)); do
    resp=$(graphql "{\"query\":\"mutation { podResume(input: {podId: \\\"$POD_ID\\\"}) { id desiredStatus } }\"}")
    err=$(printf '%s' "$resp" | jq -r '.errors[0].message // empty')
    [ -z "$err" ] && return 0
    case "$err" in
      *"free GPU"*|*"not enough"*|*capacity*|*"no longer"*)
        if [ "$i" -lt "$tries" ]; then
          log "no free GPU (attempt $i/$tries) — retrying in ${wait}s..."; sleep "$wait"; continue
        fi ;;
    esac
    die "RunPod could not start the pod: $err"
  done
  die "RunPod had no free GPU after $tries attempts: $err"
}

# Create a brand-new pod attached to the existing network volume (model + build
# already live there). Echoes the new pod id. Driven entirely by conf so it's
# reproducible for any client. Requires NETWORK_VOLUME_ID.
create_pod_on_volume() {
  [ -n "$NETWORK_VOLUME_ID" ] || die "NETWORK_VOLUME_ID not set in $CONF (needed to create/migrate a pod)"
  [ -f "$SSH_KEY.pub" ] || die "no public key at $SSH_KEY.pub"
  local pub gpus ports body resp code newid
  pub=$(cat "$SSH_KEY.pub")
  gpus=$(printf '%s' "$GPU_TYPE_IDS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
  ports=$(printf '%s' "$POD_PORTS"   | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
  body=$(jq -n --arg img "$POD_IMAGE" --arg pk "$pub" --arg jp "$JUPYTER_PASSWORD" \
    --arg name "$POD_NAME" --arg vol "$NETWORK_VOLUME_ID" --arg vmp "$VOLUME_PATH" \
    --arg cloud "$CLOUD_TYPE" --argjson gpus "$gpus" --argjson ports "$ports" \
    --argjson disk "$CONTAINER_DISK_GB" \
    '{name:$name, imageName:$img, gpuTypeIds:$gpus, gpuCount:1,
      networkVolumeId:$vol, volumeMountPath:$vmp, containerDiskInGb:$disk,
      ports:$ports, cloudType:$cloud,
      env: ({PUBLIC_KEY:$pk} + (if $jp=="" then {} else {JUPYTER_PASSWORD:$jp} end))}')
  resp=$(curl -sS -w $'\n%{http_code}' -X POST https://rest.runpod.io/v1/pods \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" -d "$body")
  code=$(printf '%s' "$resp" | tail -n1)
  if [ "$code" != "200" ] && [ "$code" != "201" ]; then
    die "create pod failed (HTTP $code): $(printf '%s' "$resp" | sed '$d' | head -c 400)"
  fi
  newid=$(printf '%s' "$resp" | sed '$d' | jq -r '.id // empty')
  [ -n "$newid" ] || die "create pod: no id in response"
  printf '%s' "$newid"
}

# Persist a new POD_ID into the conf file (so future runs use it) + update live state.
set_conf_pod_id() {
  local newid="$1"
  if [ -f "$CONF" ] && grep -q '^POD_ID=' "$CONF"; then
    sed "s|^POD_ID=.*|POD_ID=\"$newid\"|" "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
  fi
  POD_ID="$newid"
  STATE_FILE="${TMPDIR:-/tmp}/runpod-hermes-${POD_ID}.endpoint"
}

# Delete a pod (used to clean up the old one after a migrate).
terminate_pod() {
  curl -sS -o /dev/null -X DELETE "https://rest.runpod.io/v1/pods/$1" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" 2>/dev/null || true
}

# Wait for SSH; if the pod wedges on first boot (no ports for a full window),
# stop->start it once to force a clean container, then wait again. Echoes "IP PORT".
# Wait for SSH-auth readiness; if a fresh pod wedges on first boot (no SSH within
# the window), stop->start it once to force a clean container, then wait again.
# On success READY_IP / READY_PORT are set. Called IN-SHELL (no subshell) so those
# globals — and any POD_ID change from a migrate — propagate to the caller.
wait_ready_or_unwedge() {
  # Be patient: some hosts take 4-6 min to publish SSH + inject the key on boot.
  # wait_ready returns the instant auth works, so fast resumes aren't slowed — the
  # long window only matters for slow ones. Only after a full window with NO SSH
  # do we treat it as a real wedge and stop->start once (which re-incurs the boot
  # cost, so we avoid it unless genuinely stuck).
  wait_ready "${READY_TRIES:-72}" >/dev/null && return 0
  log "no SSH auth within window — cycling the pod once to unstick..."
  graphql "{\"query\":\"mutation { podStop(input: {podId: \\\"$POD_ID\\\"}) { id } }\"}" >/dev/null
  local i st
  for i in $(seq 1 30); do st=$(rest_get | jq -r '.desiredStatus // empty'); [ "$st" = "EXITED" ] && break; sleep 3; done
  resume_pod
  wait_ready "${READY_TRIES2:-72}" >/dev/null && return 0
  return 1
}

# Create a fresh pod on the volume, wait for it, repoint the conf, drop the old
# one. Sets READY_IP/READY_PORT + POD_ID. This makes capacity failures invisible.
migrate_pod() {
  local oldid="$POD_ID" newid
  log "Auto-migrate: creating a fresh pod on volume $NETWORK_VOLUME_ID ..."
  # NOTE: `die` inside $(...) only kills the subshell, so we MUST check the exit
  # code here — otherwise a failed create (e.g. RunPod "no instances available")
  # would leave newid empty and blank POD_ID in the conf. Do NOT touch the conf
  # unless we actually got a new pod id.
  newid=$(create_pod_on_volume) || die "Auto-migrate failed: could not create a replacement pod (RunPod capacity?). POD_ID left unchanged ($oldid)."
  [ -n "$newid" ] || die "Auto-migrate failed: empty pod id from create. POD_ID left unchanged ($oldid)."
  log "New pod $newid created — waiting for boot (fresh pods pull the image once)..."
  set_conf_pod_id "$newid"
  wait_ready_or_unwedge || die "migrated pod $newid never became SSH-ready"
  ok "Migrated $oldid -> $newid (conf updated)."
  if [ "$MIGRATE_TERMINATE_OLD" = "1" ] && [ -n "$oldid" ] && [ "$oldid" != "$newid" ]; then
    log "Terminating old pod $oldid ..."; terminate_pod "$oldid"
  fi
}

# Bring the pod up: resume it, or (on a capacity failure, if AUTO_MIGRATE=1)
# migrate to a fresh pod on the volume. On success READY_IP/READY_PORT + POD_ID
# reflect the running pod. MUST be called in-shell (not $()), so a migrate's
# POD_ID/endpoint updates reach cmd_up.
bring_up_pod() {
  require_ssh_key          # fail fast if the key can't do non-interactive SSH
  local resp err
  resp=$(graphql "{\"query\":\"mutation { podResume(input: {podId: \\\"$POD_ID\\\"}) { id desiredStatus } }\"}")
  err=$(printf '%s' "$resp" | jq -r '.errors[0].message // empty')
  if [ -z "$err" ]; then
    wait_ready_or_unwedge || die "pod $POD_ID never became SSH-ready"; return 0
  fi
  case "$err" in
    *"free GPU"*|*"not enough"*|*capacity*|*"no longer"*)
      if [ "$AUTO_MIGRATE" = "1" ] && [ -n "$NETWORK_VOLUME_ID" ]; then
        migrate_pod; return 0
      fi
      die "RunPod had no free GPU and auto-migrate is off (set AUTO_MIGRATE=1 + NETWORK_VOLUME_ID): $err" ;;
    *already*|*running*|*"not stopped"*)   # idempotent: already up
      wait_ready_or_unwedge || die "pod $POD_ID never became SSH-ready"; return 0 ;;
    *) die "RunPod could not start the pod: $err" ;;
  esac
}

ssh_pod() { # $1 ip  $2 port  $3.. remote command
  local ip=$1 port=$2; shift 2
  ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" -p "$port" "root@$ip" "$@"
}

# Poll until the pod is RUNNING, its SSH port is published, AND key-auth actually
# works. Sets globals READY_IP / READY_PORT (and echoes "IP PORT"). Arg $1 = max
# tries (x5s); defaults to READY_TRIES or 60.
#
# NOTE: a fresh pod publishes port 22 a bit BEFORE RunPod injects PUBLIC_KEY, so
# a port-only check races the key injection and SSH gets "Permission denied".
# We therefore require a real `ssh ... true` to succeed. Endpoints change on
# every resume — never cache them.
wait_ready() {
  local i resp status ip port tries="${1:-${READY_TRIES:-60}}"
  READY_IP=""; READY_PORT=""
  for i in $(seq 1 "$tries"); do
    resp=$(graphql "{\"query\":\"query { pod(input: {podId: \\\"$POD_ID\\\"}) { desiredStatus runtime { ports { ip privatePort publicPort } } } }\"}")
    status=$(printf '%s' "$resp" | jq -r '.data.pod.desiredStatus // empty')
    ip=$(printf '%s' "$resp" | jq -r '.data.pod.runtime.ports[]? | select(.privatePort==22) | .ip')
    port=$(printf '%s' "$resp" | jq -r '.data.pod.runtime.ports[]? | select(.privatePort==22) | .publicPort')
    if [ "$status" = "RUNNING" ] && [ -n "$ip" ] && [ "$ip" != "null" ] \
       && ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" -p "$port" "root@$ip" true 2>/dev/null; then
      READY_IP="$ip"; READY_PORT="$port"; printf '%s %s\n' "$ip" "$port"; return 0
    fi
    sleep 5
  done
  return 1
}

open_tunnel() { # $1 ip  $2 port
  pkill -f "$LOCAL_PORT:localhost:$LLAMA_PORT" 2>/dev/null || true
  ssh -f -N "${SSH_OPTS[@]}" -i "$SSH_KEY" -p "$2" "root@$1" -L "$LOCAL_PORT:localhost:$LLAMA_PORT"
}
close_tunnel() { pkill -f "$LOCAL_PORT:localhost:$LLAMA_PORT" 2>/dev/null || true; }

# Start llama-server on the pod if not already running, then wait for HTTP 200.
# NOTE: `pgrep -x` (exact process name) — `pgrep -f llama-server` would also
# match this very SSH command line and wrongly conclude it's already running.
# NOTE: setsid + full fd redirection so the SSH call returns instead of hanging
# on the backgrounded server's inherited channel.
serve() { # $1 ip  $2 port
  local ip=$1 port=$2 remote i code
  remote="if ! pgrep -x llama-server >/dev/null 2>&1; then \
setsid bash -c '\"$LLAMA_DIR/build/bin/llama-server\" -m \"$MODEL_DIR/$MODEL_FILE\" \
--host 0.0.0.0 --port $LLAMA_PORT -ngl $LLAMA_NGL -c $LLAMA_CTX -np 1 \
--api-key \"$API_SECRET\" > \"$VOLUME_PATH/llama.log\" 2>&1' </dev/null >/dev/null 2>&1 & fi; echo ok"
  ssh_pod "$ip" "$port" "$remote" >/dev/null || return 1
  for i in $(seq 1 60); do
    code=$(ssh_pod "$ip" "$port" "curl -s -o /dev/null -w '%{http_code}' http://localhost:$LLAMA_PORT/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  return 1
}

# ---- commands --------------------------------------------------------------
cmd_doctor() {
  local fail=0
  log "Dependencies:"
  for b in curl jq ssh ssh-keygen; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b"; else warn "missing: $b"; fail=1; fi
  done
  log "SSH key:"
  if [ -f "$SSH_KEY" ] && [ -f "$SSH_KEY.pub" ]; then ok "$SSH_KEY (+ .pub)"; else warn "key or .pub missing at $SSH_KEY"; fail=1; fi
  if ssh_key_usable; then ok "key usable for non-interactive SSH (no passphrase, or loaded in ssh-agent)"; else
    warn "key is passphrase-protected but NOT in ssh-agent — SSH will hang. Fix: ssh-add --apple-use-keychain $SSH_KEY"; fail=1; fi
  log "Config:"
  [ -n "$RUNPOD_API_KEY" ] && ok "RUNPOD_API_KEY set" || { warn "RUNPOD_API_KEY empty"; fail=1; }
  [ -n "$POD_ID" ]         && ok "POD_ID=$POD_ID"     || { warn "POD_ID empty"; fail=1; }
  if [ "$LLAMA_CTX" -lt 65536 ] 2>/dev/null; then warn "LLAMA_CTX=$LLAMA_CTX is < 65536 — Hermes will reject it (needs >=64K)"; fail=1; else ok "LLAMA_CTX=$LLAMA_CTX (>=64K)"; fi
  if [ -n "$RUNPOD_API_KEY" ] && [ -n "$POD_ID" ]; then
    log "RunPod API:"
    local body code
    body=$(rest_get); code=$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)
    if [ "$code" = "$POD_ID" ]; then
      ok "reachable — pod '$(printf '%s' "$body" | jq -r .name)' status=$(printf '%s' "$body" | jq -r .desiredStatus)"
      # The crux: does the pod's PUBLIC_KEY match the local public key?
      local podkey mykey
      podkey=$(printf '%s' "$body" | jq -r '.env.PUBLIC_KEY // empty')
      mykey=$(cat "$SSH_KEY.pub" 2>/dev/null)
      if [ -z "$podkey" ]; then warn "pod has NO PUBLIC_KEY env — run: $0 fix-key"
      elif printf '%s' "$podkey" | grep -q '^SHA256:'; then warn "pod PUBLIC_KEY is a FINGERPRINT, not a key — run: $0 fix-key"
      elif [ "$podkey" = "$mykey" ]; then ok "pod PUBLIC_KEY matches your public key (persistence OK)"
      else warn "pod PUBLIC_KEY differs from $SSH_KEY.pub — run: $0 fix-key"; fi
    else warn "RunPod API did not return the pod (bad key or pod id?)"; fail=1; fi
  fi
  log "Hermes CLI:"
  command -v hermes >/dev/null 2>&1 && ok "hermes at $(command -v hermes)" || warn "hermes not on PATH"
  [ "$fail" = 0 ] && ok "doctor: all good" || warn "doctor: issues above"
}

cmd_fix_key() {
  need_cfg
  [ -f "$SSH_KEY.pub" ] || die "no public key at $SSH_KEY.pub"
  local pub cur env_json resp code
  pub=$(cat "$SSH_KEY.pub")
  log "Fetching current pod env (so we merge, not clobber)..."
  cur=$(rest_get)
  printf '%s' "$cur" | jq -e '.id' >/dev/null 2>&1 || die "REST GET failed: $(printf '%s' "$cur" | head -c 300)"
  # NOTE: env is a JSON object; PATCH replaces the whole map, so merge PUBLIC_KEY in.
  env_json=$(printf '%s' "$cur" | jq --arg k "$pub" '(.env // {}) + {PUBLIC_KEY:$k}')
  log "Setting PUBLIC_KEY = your real public key line..."
  resp=$(curl -sS -w $'\n%{http_code}' -X PATCH "https://rest.runpod.io/v1/pods/$POD_ID" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
    -d "$(jq -n --argjson e "$env_json" '{env:$e}')")
  code=$(printf '%s' "$resp" | tail -n1)
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    ok "PUBLIC_KEY set. It injects on the NEXT full start."
    log "Run:  $0 cycle    (stop->start + verify), or just use it next time."
  else
    warn "REST PATCH returned HTTP $code:"; printf '%s\n' "$resp" | sed '$d' >&2
    warn "Fallback — set it in the RunPod console (Pod -> Edit -> Environment Variables):"
    printf '   PUBLIC_KEY = %s\n' "$pub"
  fi
}

cmd_cycle() {
  need_cfg
  log "Stopping pod to force a fresh container on next start..."
  graphql "{\"query\":\"mutation { podStop(input: {podId: \\\"$POD_ID\\\"}) { id desiredStatus } }\"}" >/dev/null
  local i st
  for i in $(seq 1 30); do
    st=$(rest_get | jq -r '.desiredStatus // empty')
    [ "$st" = "EXITED" ] && break
    sleep 3
  done
  log "Starting pod..."
  resume_pod
  local ep ip port
  ep=$(wait_ready) || die "pod did not become ready"
  read -r ip port <<<"$ep"
  log "Pod ready at $ip:$port — verifying key injection..."
  cmd_verify_key "$ip" "$port"
}

cmd_verify_key() { # optional: $1 ip $2 port (else resume+wait)
  need_cfg
  local ip port n
  if [ $# -ge 2 ]; then ip=$1; port=$2; else
    ep=$(wait_ready) || die "pod not ready (resume it first: $0 up)"; read -r ip port <<<"$ep"
  fi
  n=$(ssh_pod "$ip" "$port" 'grep -c "ssh-" ~/.ssh/authorized_keys 2>/dev/null || echo 0' 2>/dev/null || echo 0)
  if [ "${n:-0}" -ge 1 ] 2>/dev/null; then ok "authorized_keys has $n key(s) — SSH persistence confirmed"; else
    die "authorized_keys empty/unreachable — PUBLIC_KEY not injected. Re-run: $0 fix-key"; fi
}

cmd_bootstrap() {
  need_cfg
  log "Resuming pod for bootstrap..."
  resume_pod
  local ep ip port; ep=$(wait_ready) || die "pod not ready"; read -r ip port <<<"$ep"
  log "Bootstrapping on pod $ip:$port (this can take several minutes)..."
  # Heredoc runs remotely; variables expanded LOCALLY where they name pod paths.
  ssh_pod "$ip" "$port" bash -s <<EOF
set -e
echo "== deps =="
command -v git >/dev/null || (apt-get update -y && apt-get install -y git build-essential cmake)
python3 -m pip install -q -U "huggingface_hub[cli]" || pip install -q -U "huggingface_hub[cli]"

echo "== model =="
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_FILE" ]; then
  echo "model present: $MODEL_DIR/$MODEL_FILE"
elif [ -n "$HF_REPO" ]; then
  echo "downloading $HF_FILE from $HF_REPO ..."
  huggingface-cli download "$HF_REPO" "$HF_FILE" --local-dir "$MODEL_DIR"
  # flatten if HF put it in a subfolder
  found=\$(find "$MODEL_DIR" -name "\$(basename "$MODEL_FILE")" | head -1)
  [ -n "\$found" ] && [ "\$found" != "$MODEL_DIR/$MODEL_FILE" ] && mv "\$found" "$MODEL_DIR/$MODEL_FILE" || true
else
  echo "!! no model and HF_REPO unset — place the GGUF at $MODEL_DIR/$MODEL_FILE yourself"
fi

echo "== llama.cpp =="
if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
  echo "llama-server already built"
else
  [ -d "$LLAMA_DIR/.git" ] || git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
  cd "$LLAMA_DIR"
  cmake -B build -DGGML_CUDA=ON
  cmake --build build --config Release -j
fi
echo "== bootstrap done =="
ls -la "$LLAMA_DIR/build/bin/llama-server" "$MODEL_DIR/$MODEL_FILE"
EOF
  ok "Bootstrap complete."
}

cmd_config() {
  [ -f "$HERMES_CONFIG" ] || die "Hermes config not found at $HERMES_CONFIG"
  local bak; bak="$HERMES_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$HERMES_CONFIG" "$bak"; log "backed up -> $bak"
  # NOTE: provider 'custom' = any OpenAI-compatible local server (llama.cpp/vLLM/Ollama).
  # NOTE: context_length must equal the server -c AND be >=64K (Hermes minimum).
  # NOTE: api_key scoped here (not global OPENAI_API_KEY) so other providers are untouched.
  local blk
  blk="model:
  default: $MODEL_ALIAS
  provider: custom
  base_url: http://localhost:$LOCAL_PORT/v1
  api_key: $API_SECRET
  api_mode: chat_completions
  context_length: $LLAMA_CTX"
  local tmpblk; tmpblk=$(mktemp); printf '%s\n' "$blk" > "$tmpblk"
  if grep -q '^model:' "$HERMES_CONFIG"; then
    awk -v bf="$tmpblk" '
      BEGIN{ while((getline l < bf)>0){ b = b (b==""?"":"\n") l } }
      /^model:/ { print b; skip=1; next }
      skip && /^[A-Za-z_]/ { skip=0 }
      !skip { print }
    ' "$HERMES_CONFIG" > "$HERMES_CONFIG.tmp" && mv "$HERMES_CONFIG.tmp" "$HERMES_CONFIG"
  else
    cat "$tmpblk" "$HERMES_CONFIG" > "$HERMES_CONFIG.tmp" && mv "$HERMES_CONFIG.tmp" "$HERMES_CONFIG"
  fi
  rm -f "$tmpblk"
  ok "Hermes model block now points at localhost:$LOCAL_PORT (model '$MODEL_ALIAS')."
}

cmd_install() {
  local B="# >>> runpod-hermes wrapper >>>" E="# <<< runpod-hermes wrapper <<<"
  local conf_abs; conf_abs="$(cd "$(dirname "$CONF")" 2>/dev/null && pwd)/$(basename "$CONF")"
  [ -f "$SHELL_RC" ] || touch "$SHELL_RC"
  if grep -q '^hermes()' "$SHELL_RC" 2>/dev/null; then
    warn "an inline hermes() already exists in $SHELL_RC — remove it to avoid a name clash"
  fi
  # strip any previous managed block, then append a fresh one
  awk -v b="$B" -v e="$E" '
    $0==b{s=1} !s{print} $0==e{s=0}
  ' "$SHELL_RC" > "$SHELL_RC.tmp" && mv "$SHELL_RC.tmp" "$SHELL_RC"
  {
    printf '%s\n' "$B"
    printf 'export RUNPOD_HERMES_CONF=%q\n' "$conf_abs"
    printf 'export RUNPOD_HERMES_CLI=%q\n' "$SCRIPT_DIR/runpod-hermes.sh"
    printf 'source %q\n' "$SCRIPT_DIR/hermes-wrapper.sh"
    printf '%s\n' "$E"
  } >> "$SHELL_RC"
  ok "Wrapper wired into $SHELL_RC (conf: $conf_abs)."
  log "Activate now:  source $SHELL_RC"
}

# Create a fresh pod on the volume and record it in the conf (for onboarding a
# new client, or replacing a dead pod). Does not serve — follow with `up`.
cmd_create() {
  need_cfg
  local newid
  newid=$(create_pod_on_volume)
  set_conf_pod_id "$newid"
  ok "Created pod $newid (POD_ID written to $CONF). Next: $0 up"
}

# Ensure the pod is running & SSH-ready (resume, or auto-migrate on no capacity).
# Used by the shell wrapper. Prints the ready endpoint.
cmd_ensure() {
  need_cfg
  bring_up_pod                                   # in-shell: updates POD_ID + READY_IP/PORT
  ok "Pod ready at $READY_IP:$READY_PORT (POD_ID=$POD_ID)"
}

cmd_up() {
  need_cfg
  log "Bringing pod up (resume, or auto-migrate to a fresh pod if no capacity)..."
  bring_up_pod                                   # in-shell: updates POD_ID + READY_IP/PORT
  local ip="$READY_IP" port="$READY_PORT"
  log "Pod ready at $ip:$port (POD_ID=$POD_ID)"
  open_tunnel "$ip" "$port"; log "Tunnel localhost:$LOCAL_PORT -> pod:$LLAMA_PORT"
  log "Starting model server (first load can take ~60s)..."
  if ! serve "$ip" "$port"; then
    # Don't leak a running pod on failure.
    log "server failed to become healthy — stopping the pod to avoid a billing leak"
    graphql "{\"query\":\"mutation { podStop(input: {podId: \\\"$POD_ID\\\"}) { id } }\"}" >/dev/null
    close_tunnel
    die "model server did not become healthy — check $VOLUME_PATH/llama.log on the pod"
  fi
  printf '%s %s\n' "$ip" "$port" > "$STATE_FILE"
  [ -n "${RPH_SESSION:-}" ] && session_add "$RPH_SESSION"   # register this session
  ok "Up. Model server healthy at http://localhost:$LOCAL_PORT"
}

cmd_serve() {
  need_cfg
  local ep ip port; ep=$(wait_ready) || die "pod not running (try: $0 up)"; read -r ip port <<<"$ep"
  serve "$ip" "$port" && ok "model server healthy" || die "server not healthy"
}

cmd_down() {
  need_cfg
  local force=0; [ "${1:-}" = "--force" ] && force=1

  if [ "$force" != 1 ]; then
    # Keep-alive: leave the pod running until an explicit `down --force`.
    if [ "$KEEP_ALIVE" = 1 ]; then
      log "keep-alive is ON — leaving the pod RUNNING (stop it with: $0 down --force)"; return 0
    fi
    # Ref-count: if another hermes session is still using this pod, don't stop it.
    if [ -n "${RPH_SESSION:-}" ] && session_prune_and_any "$RPH_SESSION"; then
      log "another hermes session is still active — leaving the pod up"; return 0
    fi
  fi

  session_clear                         # last one out (or forced): clear the roster
  if [ -f "$STATE_FILE" ]; then
    local ip port; read -r ip port < "$STATE_FILE"
    ssh_pod "$ip" "$port" 'pkill -x llama-server' 2>/dev/null || true
  fi
  close_tunnel
  log "Stopping pod $POD_ID ..."
  graphql "{\"query\":\"mutation { podStop(input: {podId: \\\"$POD_ID\\\"}) { id desiredStatus } }\"}" >/dev/null
  rm -f "$STATE_FILE"
  ok "Pod stopped (GPU billing off)."
}

cmd_status() {
  need_cfg
  local body; body=$(rest_get)
  log "pod:    $(printf '%s' "$body" | jq -r '.name') ($POD_ID)"
  log "state:  $(printf '%s' "$body" | jq -r '.desiredStatus')"
  local pk; pk=$(printf '%s' "$body" | jq -r '.env.PUBLIC_KEY // "none"')
  case "$pk" in
    none)      warn "PUBLIC_KEY: none set" ;;
    SHA256:*)  warn "PUBLIC_KEY: fingerprint (BROKEN) — run fix-key" ;;
    *)         ok   "PUBLIC_KEY: key line set" ;;
  esac
  if curl -s -o /dev/null -w '%{http_code}' "http://localhost:$LOCAL_PORT/health" 2>/dev/null | grep -q 200; then
    ok "local server: healthy via tunnel (localhost:$LOCAL_PORT)"
  else
    log "local server: not reachable on localhost:$LOCAL_PORT (pod may be down / no tunnel)"
  fi
  local sf n; sf=$(sessions_file); n=0; [ -f "$sf" ] && n=$(grep -c . "$sf" 2>/dev/null || echo 0)
  log "active hermes sessions: $n   |   keep-alive: $([ "$KEEP_ALIVE" = 1 ] && echo ON || echo off)"
}

# One watchdog tick: if the pod is RUNNING and its GPU has been idle for
# >= IDLE_MINUTES, force-stop it. Safety net for forgotten / KEEP_ALIVE pods.
# Schedule it (see GUIDE); each run is a single cheap check. Needs RUNPOD_API_KEY
# in its environment (cron/launchd doesn't inherit your shell — see GUIDE).
cmd_watchdog() {
  need_cfg
  local idlef; idlef="${TMPDIR:-/tmp}/runpod-hermes-$(basename "$CONF" | tr -c 'A-Za-z0-9' '_').idle"
  local resp state ip port
  resp=$(graphql "{\"query\":\"query { pod(input: {podId: \\\"$POD_ID\\\"}) { desiredStatus runtime { ports { ip privatePort publicPort } } } }\"}")
  state=$(printf '%s' "$resp" | jq -r '.data.pod.desiredStatus // empty')
  if [ "$state" != "RUNNING" ]; then rm -f "$idlef"; log "watchdog: pod not running — nothing to do"; return 0; fi
  ip=$(printf '%s' "$resp" | jq -r '.data.pod.runtime.ports[]? | select(.privatePort==22) | .ip')
  port=$(printf '%s' "$resp" | jq -r '.data.pod.runtime.ports[]? | select(.privatePort==22) | .publicPort')
  [ -n "$ip" ] && [ "$ip" != "null" ] || { log "watchdog: no SSH endpoint yet — skip"; return 0; }
  local util
  util=$(ssh_pod "$ip" "$port" "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits" 2>/dev/null | head -1 | tr -dc '0-9')
  : "${util:=0}"
  if [ "$util" -gt 5 ] 2>/dev/null; then rm -f "$idlef"; log "watchdog: GPU busy (${util}%) — reset idle timer"; return 0; fi
  # idle: track how long. (date is fine in a plain shell script.)
  local now start elapsed; now=$(date +%s)
  if [ -f "$idlef" ]; then start=$(cat "$idlef" 2>/dev/null); else start=$now; printf '%s' "$now" > "$idlef"; fi
  case "$start" in ''|*[!0-9]*) start=$now; printf '%s' "$now" > "$idlef" ;; esac
  elapsed=$(( (now - start) / 60 ))
  log "watchdog: GPU idle ${elapsed}/${IDLE_MINUTES} min"
  if [ "$elapsed" -ge "$IDLE_MINUTES" ]; then
    log "watchdog: idle >= ${IDLE_MINUTES}m — force-stopping the pod"
    rm -f "$idlef"; cmd_down --force
  fi
}

cmd_test() {
  command -v hermes >/dev/null 2>&1 || die "hermes not on PATH — install Hermes Agent first"
  cmd_up
  log "End-to-end: one-shot through Hermes -> local model ..."
  local out; out=$(command hermes -z "Reply with only the word: READY" 2>&1) || true
  printf '\033[2m--- hermes output ---\033[0m\n%s\n\033[2m---------------------\033[0m\n' "$out"
  if printf '%s' "$out" | grep -q "READY"; then ok "PASS — Hermes reached the local model"; else warn "FAIL — see output above"; fi
  if [ "${1:-}" = "--keep" ]; then log "Leaving pod up (--keep). Stop with: $0 down"; else cmd_down; fi
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---- dispatch --------------------------------------------------------------
need curl; need jq; need ssh
cmd="${1:-}"; shift || true
case "$cmd" in
  doctor)      cmd_doctor "$@" ;;
  fix-key)     cmd_fix_key "$@" ;;
  cycle)       cmd_cycle "$@" ;;
  verify-key)  cmd_verify_key "$@" ;;
  bootstrap)   cmd_bootstrap "$@" ;;
  config)      cmd_config "$@" ;;
  install)     cmd_install "$@" ;;
  create)      cmd_create "$@" ;;
  ensure)      cmd_ensure "$@" ;;
  up)          cmd_up "$@" ;;
  serve)       cmd_serve "$@" ;;
  down)        cmd_down "$@" ;;
  stop)        cmd_down --force ;;
  status)      cmd_status "$@" ;;
  watchdog)    cmd_watchdog "$@" ;;
  test)        cmd_test "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd  (run: $0 --help)" ;;
esac
