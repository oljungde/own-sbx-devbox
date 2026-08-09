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

Requires `sbx`, Docker and `gh` on the host. See
[`docs/tutorial/`](docs/tutorial/) for the full walkthrough.

## How it fits together

```
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

## License

MIT
