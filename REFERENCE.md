# RunPod + Hermes kit — reference (the "why it works" cheat sheet)

Distilled field notes behind `runpod-hermes.sh` / `hermes-wrapper.sh`. For the
full walkthrough and command reference see **GUIDE.md**. For per-client settings
see **runpod-hermes.conf.example**.

## What this is

Run a big local GGUF model on a rented RunPod GPU, driven by an OpenAI-compatible
agent CLI (Hermes), where the **GPU only bills while you're actively chatting**.
Type `hermes` → pod resumes → llama.cpp serves the model over an SSH tunnel →
you chat → on exit the pod stops. Model weights + llama.cpp build live on a
**network volume**, so they persist across the disposable pods.

## Architecture (one place owns the lifecycle)

- `runpod-hermes.sh` — the brain. All pod lifecycle + serving logic:
  `doctor · fix-key · create · cycle · verify-key · bootstrap · config ·
   install · ensure · up · down · serve · status · test`.
- `hermes-wrapper.sh` — thin `hermes()` shell function; **delegates** to
  `runpod-hermes.sh up`/`down`. Sourced into the rc by `install`.
- One `.conf` **per client** (secrets live here; `chmod 600`). API key can come
  from the conf or the `RUNPOD_API_KEY` env var; it's never printed.

## Auto-migrate (capacity resilience)

RunPod **resume is pinned to one host**. If that host is out of GPUs you get
*"not enough free GPUs on the host machine."* With `AUTO_MIGRATE=1` +
`NETWORK_VOLUME_ID`, `up`/`ensure` then: create a fresh pod on the **same volume**
(no reinstall) → unwedge it if it stalls on first boot (stop→start once) →
rewrite `POD_ID` in the conf → terminate the old pod. Capacity misses become an
invisible ~1–3 min. List several GPUs in `GPU_TYPE_IDS` to miss less often.

## Cost / capacity / reliability

Secure Cloud **on-demand is NOT interruptible** — nobody kicks you off a RUNNING
pod; the GPU is yours until *you* stop it. You bill per hour only while RUNNING.
The risk is only at **reclaim time**: stopping releases the GPU, and a resume (or
even a fresh create) can fail when the pool is dry (*"no instances available"*).
Tradeoff: **stop-when-idle** = cheap but reclaim risk; **`KEEP_ALIVE=1`** = pod
stays RUNNING (billing) until `rph stop`, guaranteeing you keep the GPU.

## Multiple sessions

Several `hermes` windows share ONE pod. Each registers `$RPH_SESSION` (its shell
PID); `down` only stops the pod when the **last live session** exits (dead ones
pruned via `kill -0`). Keyed by conf, not POD_ID, so it survives a migrate.
`stop` / `down --force` bypasses the count. `rph status` shows the count.

## Gotchas (each cost real time — all handled by the kit)

1. **`PUBLIC_KEY` must be the full `ssh-ed25519 AAAA…` line, not a `SHA256:`
   fingerprint.** RunPod appends it to `authorized_keys` on every boot; a
   fingerprint injects garbage → SSH always fails. (Not a perms/volume problem.)
2. **A booting pod opens SSH port 22 a few seconds BEFORE the key is injected.**
   Wait for a real `ssh … true` (key auth) to succeed, not just an open port,
   or you get "Permission denied" → the model server never starts.
3. **Editing a pod's `env` (PATCH) replaces the whole map** — merge `PUBLIC_KEY`
   in, don't clobber `JUPYTER_PASSWORD` etc.
4. **Hermes refuses any context window < 64K.** Launch llama-server with
   `-c ≥ 65536` and set `context_length` to match.
5. **`pgrep -x llama-server`, never `pgrep -f`** — `-f` matches the SSH command
   string itself and the server-start guard never fires.
6. **Host key changes every new container** → `-o UserKnownHostsFile=/dev/null`.
7. **SSH ip/port change on every resume** — always fetch them live, never cache.
8. **Start the server with `setsid … </dev/null >/dev/null 2>&1 &`** or the SSH
   call hangs on the backgrounded process's channel.
9. **llama.cpp ignores the request `model` field** — any friendly alias works.
10. **Stop the pod on EVERY exit** (normal, Ctrl-C, kill, terminal close, AND a
    failed bring-up) or you leak a billing pod. Trap `INT TERM HUP`, armed before
    bring-up.
11. **A passphrase-protected key MUST be in the current shell's ssh-agent** or
    BatchMode SSH silently fails and `up` hangs. Kit preflights (`ssh_key_usable`)
    and dies fast telling you to `ssh-add --apple-use-keychain <key>`. Fresh
    terminals with a custom (non-Keychain) agent need `ssh-add` again — persist it
    in `~/.ssh/config` (`AddKeysToAgent`/`UseKeychain`) or the shell profile.
12. **Some hosts inject the key slowly on boot (~4–6 min).** Be patient (up to
    ~6 min, returns the instant SSH auth works); don't unwedge eagerly — a
    stop→start just re-incurs the slow boot.

Note: "Permission denied" alone can't tell apart (a) key-not-in-agent from (b)
key-not-yet-injected — both look identical. That's why the kit *prechecks* agent
usability (a) up front, and *waits patiently* for (b).

## Reproduce for a new client (short form)

```
cp runpod-hermes.conf.example ~/.config/runpod-hermes/<client>.conf   # fill in
alias rph="./runpod-hermes.sh -c ~/.config/runpod-hermes/<client>.conf"
rph doctor && rph create && rph bootstrap && rph config && rph test && rph install
```

Same volume for another pod later → skip `bootstrap` (model+build already there).

## API surface used

- GraphQL `https://api.runpod.io/graphql` — `podResume` / `podStop` (lifecycle).
- REST `https://rest.runpod.io/v1/pods` — `GET` (status/env), `PATCH` (env, e.g.
  fix-key), `POST` (create pod with `networkVolumeId`), `DELETE` (terminate).
- `runpodctl` is intentionally avoided (auth quirk); raw API is used instead.
