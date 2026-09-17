# devbox

A teachable Claude Code sandbox built on [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/).

One sandbox, many projects — with your global agents, skills and commands
mounted in read-only instead of copied into every repository.

> **Documentation is in German.** This project is course material for a
> German-speaking workshop, so the tutorial under [`docs/`](docs/) and the
> comments inside `v1/Dockerfile` and `v1/devbox.sh` are written in
> German by design. This README is the only English document.

## What you get

The toolchain below describes `v1/` (variant 1). `v2/` and `v3/` ship
their own Dockerfiles with the same core plus per-variant additions — see
[Three variants](#three-variants).

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
cp v1/devbox.conf.example ~/.config/devbox/devbox.conf
$EDITOR ~/.config/devbox/devbox.conf     # point WORKSPACES at your project root

./v1/devbox.sh doctor
./v1/devbox.sh build                 # builds the image, registers the template
./v1/devbox.sh up privat             # creates the sandbox and starts Claude
```

Requires `sbx` and a **local** Docker daemon on the host — `sbx` alone does not
need Docker Desktop, but devbox builds its own image with `docker build`, so it
does. See [`docs/tutorial-v1/00-vorbereitung.md`](docs/tutorial-v1/00-vorbereitung.md)
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

See [`docs/tutorial-v1/`](docs/tutorial-v1/) for the full walkthrough and
[`docs/cheatsheet-v1.md`](docs/cheatsheet-v1.md) for every command on one page.

## Three variants

This repository ships **three** takes on the same idea. They share nothing but
the `sbx` concepts underneath, and they can run side by side on one machine.

|                        | `v1/` (variant 1)          | `v2/` (variant 2)                   | `v3/` (variant 3)                      |
| ---------------------- | -------------------------- | ----------------------------------- | -------------------------------------- |
| Sandboxes              | one per profile            | exactly one, machine-wide           | **one per project**, one shared image  |
| Invocation             | `./v1/devbox.sh up privat` | `solobox up`, from inside a project | `sbx-claude up`, from inside a project |
| Config file            | required                   | optional                            | optional                               |
| Global skills / agents | opt-in per profile         | always on                           | always on (skills via `sbx skills`)    |
| Global hooks & plugins | only via `SHARE_ALL`       | always on, filtered                 | plugins yes, hooks **replaced**        |
| Claude starts in       | the primary workspace      | your current project directory      | your current project directory         |
| Permission mode        | image default              | `acceptEdits`                       | `bypassPermissions` **+ ask on git**   |
| Desktop notifications  | suppressed                 | suppressed                          | **works**, via a host watcher          |

Variant 2 exists for the case where you want your entire global Claude setup —
skills, agents, commands, rules, hooks, plugins — available in every project
without copying it anywhere, and you are willing to trade the isolation that
separate profiles give you. Its tutorial is
[`docs/tutorial-v2/`](docs/tutorial-v2/), its command reference
[`docs/cheatsheet-v2.md`](docs/cheatsheet-v2.md).

```bash
chmod +x v2/solobox.sh
./v2/solobox.sh install     # symlink into ~/.local/bin
cd ~/dev/own/some-project
solobox up                       # builds, creates the sandbox, starts Claude here
```

Variant 3 moves the sandbox boundary onto the project boundary: every project
gets its own sandbox, all built from one image. That buys two things the other
two cannot offer — a completion notification that actually works inside a Linux
container (an event file plus a host-side watcher, because the container can
neither call macOS APIs nor reach the host), and permissions that never prompt
except on git. It pays for them with one `/login` per project and with the fact
that a rebuilt image never reaches existing sandboxes. Its documentation is
self-contained under [`v3/docs/`](v3/docs/).

```bash
chmod +x v3/sbx-claude.sh v3/hooks/*.sh
./v3/sbx-claude.sh install --watcher   # symlink + LaunchAgent for notifications
./v3/sbx-claude.sh build               # one image for every project
cd ~/dev/own/some-project
sbx-claude up                          # creates this project's sandbox, starts Claude
```

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
[`docs/tutorial-v1/`](docs/tutorial-v1/) walks you through building the same thing
from an empty directory, in seven chapters that each end in a working state.
Reading `v1/devbox.sh` and `v1/Dockerfile` top to bottom is the fastest
way to understand what `sbx` actually does — every section is commented.

## Design notes

- The wrapper deliberately uses **only stable `sbx` flags**. `sbx kit` and
  `sbx skills` are marked EXPERIMENTAL ("may change or be removed in future
  releases"), so the declarative kit variant lives in `v1/kit/kit.yaml` as
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
- Variant 3 treats the shared event directory as a **trust boundary in the other
  direction**: it is a channel out of the sandbox onto the host, so the watcher
  accepts exactly one word from a fixed list and one integer, composes the
  notification text itself, and never passes container-supplied strings to a
  shell or to AppleScript. See [`v3/docs/architektur.md`](v3/docs/architektur.md).

## License

MIT
