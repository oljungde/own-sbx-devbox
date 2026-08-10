# devbox

A teachable Claude Code sandbox built on [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/).

One sandbox, many projects — with your global agents, skills and commands
mounted in read-only instead of copied into every repository.

> **Documentation is in German.** This project is course material for a
> German-speaking workshop, so the tutorial under [`docs/`](docs/) and the
> comments inside `devbox/Dockerfile` and `devbox/devbox.sh` are written in
> German by design. This README is the only English document.

## What you get

- **Python 3.10, 3.12 and 3.14** side by side (3.12 is the default; `uv` picks
  the right one per project from `.python-version`)
- `uv`, `pip`, `poetry`, `ruff`
- Node.js 24, `npm`, `pnpm`
- `git`, `gh`, `jq`, `ripgrep`, `build-essential`
- Playwright with Chromium
- [Aikido Safe Chain](https://github.com/AikidoSec/safe-chain) — scans packages
  for malware before they are installed; switch it off with
  `DEVBOX_SAFE_CHAIN=0`
- A deny-by-default network policy, scoped per sandbox

## Quick start

```bash
git clone <your-fork> ~/dev/own/devbox
cd ~/dev/own/devbox

mkdir -p ~/.config/devbox
cp devbox/devbox.conf.example ~/.config/devbox/devbox.conf
$EDITOR ~/.config/devbox/devbox.conf     # point WORKSPACES at your project root

./devbox/devbox.sh doctor
./devbox/devbox.sh build                 # builds the image, registers the template
./devbox/devbox.sh up privat             # creates the sandbox and starts Claude
```

Requires `sbx` and a **local** Docker daemon on the host — `sbx` alone does not
need Docker Desktop, but devbox builds its own image with `docker build`, so it
does. See [`docs/tutorial/00-vorbereitung.md`](docs/tutorial/00-vorbereitung.md)
for installation on macOS, Linux and Windows.

## Platform support

|             | Supported                               | Not supported                                |
| ----------- | --------------------------------------- | -------------------------------------------- |
| **macOS**   | 14 (Sonoma) or later, Apple silicon     | Intel Macs                                   |
| **Windows** | 11 on x86_64, via **WSL2**              | Windows 10, Windows on ARM, PowerShell alone |
| **Linux**   | Ubuntu 24.04 or later, x86_64 / aarch64 | older Ubuntu, hosts without KVM              |

`devbox.sh` is a bash script, so on Windows run it inside WSL2 — and keep the
repository in the WSL filesystem, not under `/mnt/c/`. Git Bash mostly works but
rewrites paths to `/c/Users/...`, which surprises `sbx create` mount arguments.

See [`docs/tutorial/`](docs/tutorial/) for the full walkthrough and
[`docs/cheatsheet.md`](docs/cheatsheet.md) for every command on one page.

## How it fits together

```bash
Dockerfile  --docker build-->  image  --sbx template load-->  template
                                                                 |
                                                          sbx create -t
                                                                 v
                                                              sandbox
```

The template is built once per machine. Sandboxes are created from it and are
long-lived; your project files stay on the host and are bind-mounted in.

## Learn it, don't just run it

This repository is the reference implementation. The tutorial in
[`docs/tutorial/`](docs/tutorial/) walks you through building the same thing
from an empty directory, in seven chapters that each end in a working state.
Reading `devbox/devbox.sh` and `devbox/Dockerfile` top to bottom is the fastest
way to understand what `sbx` actually does — every section is commented.

## Design notes

- The wrapper deliberately uses **only stable `sbx` flags**. `sbx kit` and
  `sbx skills` are marked EXPERIMENTAL ("may change or be removed in future
  releases"), so the declarative kit variant lives in `devbox/kit/kit.yaml` as
  an optional extra rather than in the critical path.
- Network rules are applied with `--sandbox` scope only, never globally, so
  another `sbx` setup on the same machine is left untouched.
- Mount a **parent directory**, not individual projects: workspaces can only be
  set when the sandbox is created, so anything missing later costs a rebuild.
- Global skills are mounted read-only but not linked, because `sbx` keeps its own
  machine-wide store at that path. If your machine only runs your own sandboxes,
  `SHARE_ALL=1` in a profile opts out of that separation and also enables every
  installed plugin. It is off by default — see
  [`docs/architektur.md`](docs/architektur.md).

## License

MIT
