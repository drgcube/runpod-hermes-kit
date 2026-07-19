# RunPod + llama.cpp + Hermes — on-demand local model kit

Run a big local model on a rented RunPod GPU, driven by the **Hermes Agent** CLI,
where the GPU **only bills while you're actually chatting**. Type `hermes`, the
pod spins up, serves the model, you chat; on exit the pod stops itself.

This kit makes that setup **repeatable** for any client / machine / model. It
bakes in every gotcha discovered the hard way (see [Gotchas](#gotchas-read-this)).

```
your Mac                          RunPod GPU pod (billed only while up)
┌───────────────┐   SSH tunnel    ┌──────────────────────────────────┐
│ hermes CLI    │  localhost:8000 │ llama.cpp llama-server :8000     │
│  └ hermes()   │────────────────▶│  └ your-model.gguf on /workspace │
│    wrapper    │   resume/stop    │     (persistent network volume)  │
└───────────────┘   (RunPod API)  └──────────────────────────────────┘
```

---

## Files

| File | What it is |
|---|---|
| `runpod-hermes.sh` | Admin/setup CLI (`doctor`, `fix-key`, `bootstrap`, `config`, `install`, `up`/`down`, `test`, …) |
| `hermes-wrapper.sh` | The `hermes()` shell function (on-demand pod lifecycle). Sourced into your rc. |
| `runpod-hermes.conf.example` | Per-client config template. Copy + fill in per client/machine. |
| `GUIDE.md` | This file. |

One **conf file per client/machine**. Everything else is generic.

---

## Prerequisites

**Local machine:** `bash` or `zsh`, `curl`, `jq`, `ssh`, an ed25519 SSH key
(`ssh-keygen -t ed25519`), and the **Hermes Agent** CLI installed
(`hermes` on your PATH).

**RunPod:** an account, an **API key**
(https://www.runpod.io/console/user/settings → API Keys), and a **pod** with a
GPU and a **network volume** (so the model + llama.cpp build survive stop/resume).

Pick a GPU with enough VRAM for `model weights + KV cache`. Rule of thumb:
a 27–32B model at Q8 (~30GB) + 128K context KV fits comfortably on an **A100 80GB**.
Smaller quant (Q4/Q5) or context → smaller GPU.

---

## Creating a pod (one-time, per client)

Easiest via the RunPod **console**: New Pod → pick GPU → attach a **Network
Volume** (e.g. 60–100GB) mounted at `/workspace` → image
`runpod/pytorch:...-cuda...` → expose TCP port **22** (SSH). Note the **pod id**.

> You can also create pods via the RunPod API / the `@runpod/mcp-server` MCP
> (`create-pod`, `create-network-volume`). The console is simplest for a one-off.

The model weights and llama.cpp build live on the network volume, so they
persist across stop/resume. Only the **container filesystem** is ephemeral —
which is exactly why the SSH key needs the `PUBLIC_KEY` trick below.

---

## Quickstart (the happy path)

```bash
cd ~/runpod-hermes-kit

# 1. One config per client (keep secrets here; chmod 600).
mkdir -p ~/.config/runpod-hermes
cp runpod-hermes.conf.example ~/.config/runpod-hermes/acme.conf
chmod 600 ~/.config/runpod-hermes/acme.conf
$EDITOR ~/.config/runpod-hermes/acme.conf     # fill in API key, model, volume id, etc.

CONF=~/.config/runpod-hermes/acme.conf
alias rph="./runpod-hermes.sh -c $CONF"

# 2. Sanity check everything.
rph doctor

# 3. Get a pod. Either set POD_ID in the conf for an existing pod, OR create one
#    on your network volume (writes POD_ID into the conf for you):
rph create                     # needs NETWORK_VOLUME_ID set in the conf

# 4. Make the SSH key survive pod stop/resume (THE critical fix), then verify.
#    (Skip if you used `create` — the key is baked in at creation.)
rph fix-key
rph cycle                      # stop→start + confirm the key auto-injected

# 5. Put llama.cpp + the model on the pod (one-time; skip if the volume already
#    has them from another pod — the volume is shared/reusable).
rph bootstrap

# 6. Point Hermes at the local server (backs up your config.yaml first).
rph config

# 7. Prove it end-to-end (spins up, one-shot through Hermes, spins down).
rph test

# 8. Install the on-demand wrapper into your shell.
rph install
source ~/.zshrc

# Now just use it:
hermes                          # pod boots, you chat, pod stops on exit
```

Day-to-day you only ever type `hermes`. Everything else is setup.

**On a brand-new machine (client already set up once):** copy the kit + that
client's `.conf`, then just `rph doctor` and `rph install`. Because the model +
build live on the network volume, there's nothing to rebuild — and if the old
pod can't resume, auto-migrate makes a fresh one automatically.

---

## Command reference (`runpod-hermes.sh`)

| Command | Does |
|---|---|
| `doctor` | Checks deps, keys, API reachability, **and whether the pod's `PUBLIC_KEY` matches your key** (persistence health). |
| `fix-key` | Sets the pod's `PUBLIC_KEY` env to your real public key (merges with existing env). *The* persistence fix. |
| `create` | Creates a fresh pod on `NETWORK_VOLUME_ID` (key baked in) and writes its `POD_ID` into the conf. For onboarding or replacing a dead pod. |
| `cycle` | stop→start the pod, then verify the key was auto-injected. |
| `verify-key` | SSH in and confirm `authorized_keys` has your key. |
| `bootstrap` | On the pod: install deps, build llama.cpp (CUDA), download the model. Idempotent. |
| `config` | Rewrites the `model:` block in `~/.hermes/config.yaml` to point at the local server (timestamped backup first). |
| `install` | Wires `hermes-wrapper.sh` into your shell rc (between markers, idempotent). |
| `ensure` | Resume the pod, or **auto-migrate** to a fresh pod on the volume if its host is out of GPUs. |
| `up` | `ensure` + tunnel + start server (leaves it running). Registers a session. |
| `down` | Stop server+pod+tunnel **only if this is the last session** (and `KEEP_ALIVE` is off). |
| `stop` | **Force-stop** the pod now, regardless of sessions or `KEEP_ALIVE`. |
| `serve` | (pod already up) ensure the model server is running + healthy. |
| `status` | Pod state, `PUBLIC_KEY` health, server reachability, **active sessions + keep-alive**. |
| `test [--keep]` | Full end-to-end one-shot through Hermes. `--keep` leaves the pod up. |

Pass a specific conf with `-c PATH` (or set `RUNPOD_HERMES_CONF`). The API key
is read from the conf **or** the `RUNPOD_API_KEY` env var, and is never printed.

---

## Auto-migrate — capacity resilience (why you rarely babysit this)

RunPod **resume is pinned to one physical host**. Usually that host still has
your GPU free and resume is instant. But if it's full you get *"not enough free
GPUs on the host machine"* and the pod won't start.

The kit handles this for you. When a resume hits that error and
`AUTO_MIGRATE=1` + `NETWORK_VOLUME_ID` is set, `up`/`ensure` automatically:

1. **Creates a fresh pod** on the *same network volume* (model + build already
   there — nothing re-downloads or rebuilds), requesting any GPU in `GPU_TYPE_IDS`.
2. **Waits for it to boot** — and if a fresh pod *wedges* on first boot (a known
   RunPod quirk: `uptime 0`, no SSH), it stop→starts it once to unstick it.
3. **Repoints `POD_ID` in your conf** so every future run uses the new pod.
4. **Terminates the old** unstartable pod (`MIGRATE_TERMINATE_OLD=1`).

So `hermes` (or `rph up`) just works — a capacity miss becomes an extra ~1–3 min
the first time (fresh-pod image pull) and is invisible after. Knobs:

| Conf var | Meaning |
|---|---|
| `NETWORK_VOLUME_ID` | The volume with model+build. **Required** for create/migrate. |
| `GPU_TYPE_IDS` | Comma list of acceptable GPUs (first available wins). Add more to miss less. |
| `AUTO_MIGRATE` | `1` = recreate on capacity failure; `0` = fail with the API message. |
| `MIGRATE_TERMINATE_OLD` | `1` = delete the old pod after migrating; `0` = keep it. |
| `POD_IMAGE`,`CONTAINER_DISK_GB`,`POD_PORTS`,`CLOUD_TYPE`,`POD_NAME` | New-pod shape. |

> To reduce capacity misses at the source, list a roomier/cheaper GPU that still
> fits your model in `GPU_TYPE_IDS` (e.g. add `NVIDIA A100 80GB PCIe`, or a 48GB
> card for smaller quant/context).

The shell wrapper delegates its whole lifecycle to `runpod-hermes.sh up`/`down`,
so all of the above applies to daily `hermes` use, not just manual CLI runs.

---

## Gotchas (READ THIS)

These are the things that cost hours. The kit handles them for you — documented
so you understand *why*.

1. **`PUBLIC_KEY` must be the full key line, not a fingerprint.** RunPod's images
   append `$PUBLIC_KEY` to `~/.ssh/authorized_keys` on **every** boot. If it
   holds a `SHA256:…` fingerprint (a common mistake), it injects garbage and SSH
   fails after every resume. `fix-key` sets the real `ssh-ed25519 AAAA… ` line.
   This — not file permissions or the network volume — is why keys "don't
   persist". `doctor`/`status` flag a fingerprint value explicitly.

2. **`update-pod`/PATCH replaces the whole `env` map.** So `fix-key` fetches the
   current env and *merges* `PUBLIC_KEY` in — otherwise you'd wipe
   `JUPYTER_PASSWORD` etc.

3. **Hermes requires a ≥ 64K context window.** It flat-out refuses a model
   reporting less. llama-server must launch with `-c 65536` or more (kit default
   `131072`), and `config.yaml`'s `context_length` must match. `-c 8192` → Hermes
   errors out. `doctor` warns if `LLAMA_CTX < 65536`.

4. **`pgrep -x llama-server`, never `pgrep -f`.** `-f` matches the whole command
   line, and the SSH command *string* contains "llama-server" — so it matches
   itself and the server-start guard never fires. `-x` matches the exact process
   name only.

5. **SSH host key changes on every new container.** All ssh calls use
   `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no` so you never hit
   "REMOTE HOST IDENTIFICATION HAS CHANGED".

5b. **A booting pod publishes the SSH port BEFORE the key is injected.** RunPod
   opens port 22 a few seconds before its startup script appends `PUBLIC_KEY` to
   `authorized_keys`. So a port-only readiness check races the injection and SSH
   gets "Permission denied," which cascades into the model server never starting.
   `wait_ready` therefore blocks until a real `ssh … true` (key auth) succeeds —
   not just until the port is open.

6. **SSH ip/port change on every resume.** Never hardcode them — the kit pulls
   them live from the RunPod API each time.

7. **Starting the server over SSH can hang the SSH call.** Use
   `setsid … </dev/null >/dev/null 2>&1 &` so the session returns instead of
   waiting on the backgrounded server's inherited channel.

8. **llama.cpp ignores the request `model` field.** It serves the one loaded
   model regardless, so `model.default` in Hermes can be any friendly name.

9. **Thinking models split output.** This class of model returns its
   chain-of-thought in `reasoning_content` and the answer in `content`; Hermes'
   `chat_completions` mode handles that correctly.

10. **A passphrase-protected key must be in ssh-agent, or every SSH silently
    fails.** The kit's SSH uses `BatchMode` (no prompts). If your key has a
    passphrase and isn't loaded in the *current shell's* agent, auth fails on
    every attempt and `up` hangs waiting. The kit now **preflights** this
    (`ssh_key_usable`) and, if the key is unusable, dies immediately with:
    `ssh-add --apple-use-keychain <key>`. It also shows in `doctor`. NB: a
    passphrase key is only loaded per-agent — a *fresh terminal* with a custom
    (non-Keychain) agent won't have it until you `ssh-add` again, so persist it
    (see "First-time SSH setup" below).

11. **Some hosts are slow to inject the key on boot (up to ~4–6 min).** Don't
    treat a slow resume as a wedge. `wait_ready` waits up to ~6 min (returning
    the instant SSH works), and only stop→starts as a genuine last resort — an
    over-eager unwedge just re-incurs the boot cost.

---

## First-time SSH setup (do this once per machine)

Non-interactive SSH needs your key usable without a prompt. If your key has a
passphrase, load it into the agent — and persist it so every new terminal has it:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519   # macOS: stores passphrase in Keychain
```

Then ensure new terminals auto-load it. In `~/.ssh/config`:

```
Host *
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519
```

(If you run a **custom** ssh-agent from your shell profile instead of the macOS
one, add `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` to that profile so
each new shell loads the key.) Verify anytime with `ssh-add -l` or `rph doctor`.

---

## Cost, capacity & reliability (read this — it's the core tradeoff)

**You are NOT billed while the pod is stopped, and you CANNOT be kicked off a
running pod.** On RunPod **Secure Cloud on-demand** (what this kit uses), the A100
is yours for as long as the pod stays RUNNING — no one preempts it. (Only
*Spot/Community interruptible* pods can be evicted mid-run; this kit does not use
those.) You pay per hour **only while RUNNING** (~$1–2/hr for an A100).

The catch is **at resume time, not run time.** Stopping the pod (to save money)
**releases the GPU back to the pool.** Your data survives (it's on the network
volume + disk), but the physical GPU is no longer reserved. When you come back:

- **Resume** tries to restart on the pod's *original host* — if it's full you get
  *"not enough free GPUs on the host machine."*
- **Auto-migrate** then tries to create a fresh pod on *any* host — but if the
  whole pool is dry you get *"no instances currently available."*

So the "only bill while chatting" design **trades cost for a reclaim risk**:

| Mode | Cost | GPU guarantee |
|---|---|---|
| **Stop when idle** (default) | Cheap — pay only while chatting | Might not get an A100 *back* on resume when the pool is tight |
| **`KEEP_ALIVE=1`** (keep running) | ~$1–2/hr continuous (~$36/day) | Rock-solid — it's yours until *you* `rph stop` |

Use `KEEP_ALIVE=1` (in the conf, or `KEEP_ALIVE=1 hermes` for one run) during a
heavy work session when you can't afford to lose the GPU; then `rph stop` when
you're truly done. Otherwise the default auto-stops and you accept the occasional
"wait for capacity."

### Multiple sessions share one pod (safely)

Several `hermes` windows use the **same** pod. Each registers a session id; the
pod is only stopped when the **last** session exits — so **closing one window
won't kill a pod another window is using** (this used to happen). Dead/crashed
sessions are auto-pruned, so they can't pin the pod forever. `rph status` shows
the active session count.

### Avoid a leaked (forgotten-running) pod

The wrapper stops the pod when the last `hermes` exits — including Ctrl-C, `kill`,
and terminal close (via a `trap`). Nothing catches a hard SIGKILL / lost network,
so:
- `rph status` — is it up right now? (also shows sessions + keep-alive)
- `rph down` — stop if you're the last session; `rph stop` — force-stop now.
- Optional watchdog: a cron running `status` that alerts/`stop`s if the pod is up
  but GPU-idle for N minutes. RunPod also has account-level idle timeouts.

> Note: management subcommands (`hermes update|config|model|mcp|skills|--help|…`)
> are intercepted by the wrapper and run **without** touching the pod — only real
> chat sessions spin it up.

---

## Reproducing this for a new client (full recipe)

The end-to-end sequence to onboard a brand-new client from scratch:

```bash
# 0. One-time: a network volume in your target region (console or MCP
#    create-network-volume). Note its id → NETWORK_VOLUME_ID.
# 1. Config
cp runpod-hermes.conf.example ~/.config/runpod-hermes/<client>.conf
chmod 600 ~/.config/runpod-hermes/<client>.conf
#    Fill in: RUNPOD_API_KEY (or env), NETWORK_VOLUME_ID, model (HF_REPO/HF_FILE/
#    MODEL_FILE/MODEL_DIR), LLAMA_CTX (≥64K, fits VRAM), API_SECRET, MODEL_ALIAS.
alias rph="./runpod-hermes.sh -c ~/.config/runpod-hermes/<client>.conf"

rph doctor            # preflight
rph create            # make the pod on the volume (POD_ID written to conf; key baked in)
rph bootstrap         # build llama.cpp + download the model onto the volume (one-time, slow)
rph config            # point that machine's Hermes at the local server
rph test              # end-to-end proof
rph install           # wire the `hermes` wrapper into the shell
```

After this, the client's daily use is just `hermes`, and capacity misses
self-heal via auto-migrate. Reusing the same volume for another pod later? Skip
`bootstrap` — the model + build are already on it.

### Adapting the pieces

- **New machine (same client):** copy the kit + `.conf`; `rph doctor` then
  `rph install`. Nothing rebuilds (volume). Each machine can use its own SSH key
  — re-run `rph fix-key` (or `rph create`) so its key is injected.
- **Different model:** set `HF_REPO`/`HF_FILE`/`MODEL_FILE`/`MODEL_DIR`, size
  `LLAMA_CTX` to fit VRAM (keep ≥ 64K), pick `GPU_TYPE_IDS` big enough, then
  `bootstrap` + `config`.
- **Different GPU / cheaper / more available:** edit `GPU_TYPE_IDS` (list several;
  first available wins) and `CLOUD_TYPE`. Must fit `weights + KV(context)`.
- **Different server (vLLM / Ollama / LM Studio):** OpenAI-compatible — keep Hermes
  `provider: custom` + right `base_url`; only the pod-side launch command changes.
- **Different agent (not Hermes):** point anything OpenAI-compatible at the tunnel
  `http://localhost:<LOCAL_PORT>/v1` with `API_SECRET` as its key.
- **bash instead of zsh:** set `SHELL_RC=~/.bashrc`; wrapper is bash+zsh safe.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `hermes` hangs silently on "Bringing pod up…" | Passphrase key not in this terminal's ssh-agent → BatchMode SSH keeps failing. Fix: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`. (The kit now fails fast on this instead of hanging; `rph doctor` flags it.) |
| SSH `Permission denied (publickey)` after resume | `PUBLIC_KEY` wrong/missing → `fix-key` then `cycle`. Confirm with `verify-key`. Also check your key is in ssh-agent (`ssh-add -l`). |
| Hermes: "context window … below the minimum 64,000" | `LLAMA_CTX` too small → raise to ≥65536, restart server, match `context_length`. |
| Model server never healthy | Check `/workspace/llama.log` on the pod; verify the GGUF path and that llama.cpp built with CUDA (`-ngl` needs a CUDA build). |
| `pgrep`/server "already running" but nothing serves | You used `pgrep -f` somewhere — use `pgrep -x`. |
| Pod won't stay stopped / keeps billing | A leaked session → `down`. Check for stray tunnels: `pgrep -fl "localhost:8000"`. |
| "not enough free GPUs on the host machine" on resume | Host is full. With `AUTO_MIGRATE=1` + `NETWORK_VOLUME_ID` the kit recreates on a free host automatically. To force it: `rph up`. To do it by hand: `rph create` (new pod on the volume). |
| Fresh pod stuck at `uptime 0`, no SSH | First-boot wedge — the kit stop→starts it once automatically. Manually: `restart-pod`, or `rph up` again. |
| `runpodctl` says Unauthorized | Known quirk; this kit uses the REST/GraphQL API directly instead. |
