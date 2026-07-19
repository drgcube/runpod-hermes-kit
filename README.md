# runpod-hermes-kit

Run a big local GGUF model on an **on-demand RunPod GPU**, driven by an
OpenAI-compatible agent CLI (built for [Hermes](https://github.com/NousResearch/hermes)),
where the **GPU only bills while you're actively chatting**.

Type `hermes` → the pod resumes → `llama.cpp` serves your model over an SSH
tunnel → you chat → on exit the pod stops itself. Your model weights + build live
on a persistent network volume, so the pods are disposable and cheap.

## Highlights

- **On-demand billing** — pod spins up on `hermes`, stops on exit (even on
  Ctrl-C / closed terminal). On-demand pods aren't interruptible: nobody kicks
  you off a *running* pod. Need to guarantee the GPU across a heavy session?
  `KEEP_ALIVE=1` keeps it up until you `stop`.
- **Auto-migrate** — if a pod's host is out of GPUs, it creates a fresh pod on
  the same volume, repoints config, and continues. Capacity misses become
  invisible.
- **Multi-session safe** — several `hermes` windows share one pod; it only stops
  when the last session exits, so closing one window won't kill another's.
- **Reproducible** — one `.conf` per client/machine; `create → bootstrap →
  config → test → install` scripts the whole setup.
- **Battle-tested guardrails** — every field-learned gotcha is handled (SSH key
  persistence, key-injection timing, ssh-agent checks, ≥64K context, host-key
  churn, leak prevention). See [`GUIDE.md`](GUIDE.md) and [`REFERENCE.md`](REFERENCE.md).

## Quickstart

```bash
cp runpod-hermes.conf.example ~/.config/runpod-hermes/myclient.conf   # fill in
chmod 600 ~/.config/runpod-hermes/myclient.conf
alias rph="./runpod-hermes.sh -c ~/.config/runpod-hermes/myclient.conf"

rph doctor      # preflight
rph create      # make a pod on your network volume
rph bootstrap   # build llama.cpp + download the model (one-time)
rph config      # point the agent at the local server
rph test        # end-to-end proof
rph install     # wire the `hermes` wrapper into your shell
```

Full walkthrough → **[GUIDE.md](GUIDE.md)**. Design notes & gotchas →
**[REFERENCE.md](REFERENCE.md)**.

## Files

| File | Purpose |
|---|---|
| `runpod-hermes.sh` | Admin/setup CLI (all pod lifecycle + serving logic) |
| `hermes-wrapper.sh` | The on-demand `hermes()` shell function |
| `runpod-hermes.conf.example` | Per-client config template (**no secrets** — fill your own) |
| `GUIDE.md` | Full playbook |
| `REFERENCE.md` | Architecture + gotchas cheat-sheet |

## Security

This repo ships **no secrets**. Your RunPod API key stays in your shell env, and
per-client secrets (server API secret, etc.) live in a local `.conf` you create
from the template — `*.conf` is git-ignored. Never commit a filled-in config.

## Acknowledgments

Made in collaboration with **elura172**.
