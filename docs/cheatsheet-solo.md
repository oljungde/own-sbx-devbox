# Cheat Sheet — solobox

Alles für **Variante 2**: genau eine Sandbox systemweit. Für Variante 1 (mehrere
Sandboxes nach Profil) siehe [cheatsheet.md](cheatsheet.md).

---

## Von Null bis ins Projekt

```bash
# 1  Ausführbar machen und auf den PATH legen
chmod +x solobox/solobox.sh
./solobox/solobox.sh install          # -> ~/.local/bin/solobox

# 2  Host prüfen
solobox doctor

# 3  Image bauen und als sbx-Template laden — einmal pro Maschine, ~5,9 GB
solobox build

# 4  Ins Projekt gehen und starten
cd ~/dev/own/mein-projekt
solobox up                            # legt die Sandbox beim ersten Mal an
```

Beim **ersten** `up` meldest du dich einmal bei Claude an. Ab dem zweiten startet
Claude direkt in dem Ordner, in dem du stehst.

## Täglich

```bash
cd ~/dev/own/irgendein-projekt
solobox up                # Claude hier starten
solobox up ~/dev/work/xy  # oder anderswo
solobox shell             # bash statt Claude
solobox status            # was läuft, mit welchen Wurzeln
```

## Wenn sich auf dem Host etwas geändert hat

| Geändert                          | Kommando                               | Wirkt                     |
| --------------------------------- | -------------------------------------- | ------------------------- |
| Neuer Skill in `~/.claude/skills` | `solobox sync`                         | nach Neustart der Sitzung |
| Plugin installiert/aktiviert      | `solobox sync`                         | nach Neustart der Sitzung |
| Neuer MCP-Server (`sbx mcp add`)  | `MCP_SERVERS` ergänzen, `solobox sync` | sofort                    |
| Neuer Agent / Command / Rule      | nichts — die sind gemountet            | sofort                    |
| Dockerfile geändert               | `solobox update`                       | erst nach `rm` + `up`     |
| `ROOTS` geändert                  | `solobox rm && solobox up`             | kostet den Login          |

## Die Kommandos

| Kommando                  | Was es tut                                                                 |
| ------------------------- | -------------------------------------------------------------------------- |
| `solobox up [pfad]`       | Sandbox anlegen (einmalig) und Claude starten — in `$PWD` oder in `[pfad]` |
| `solobox build [--force]` | Image bauen, als sbx-Template laden                                        |
| `solobox sync`            | Skills, Settings, MCP in die laufende Sandbox nachziehen                   |
| `solobox shell [pfad]`    | bash in der Sandbox                                                        |
| `solobox allow <host>`    | Host für die Sandbox freigeben (bis zum Neuanlegen)                        |
| `solobox status`          | Template, Sandbox, Wurzeln, MCP-Server, Nachbarn                           |
| `solobox update`          | Template neu bauen und sagen, was das der Sandbox _nicht_ bringt           |
| `solobox install`         | Symlink nach `~/.local/bin/solobox`                                        |
| `solobox doctor`          | Host prüfen                                                                |
| `solobox rm`              | Sandbox entfernen (fragt nach)                                             |

## Die rohen `sbx`-Kommandos dahinter

```bash
# Anlegen — Wurzeln + globale Claude-Ordner, alles read-only außer ~/dev
# ⚠️ nur Verzeichnisse; eine einzelne Datei lehnt sbx ab
sbx create -t solobox/base:latest --name solobox claude \
  ~/dev \
  ~/.claude/agents:ro ~/.claude/skills:ro ~/.claude/commands:ro \
  ~/.claude/rules:ro ~/.claude/plugins:ro ~/.claude/hooks:ro

# Git-Identität (statt ~/.gitconfig einzuhängen — das geht nicht)
sbx exec solobox git config --global user.name  "$(git config --global --get user.name)"
sbx exec solobox git config --global user.email "$(git config --global --get user.email)"

# Starten — im Projekt
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude

# Starten — im Primary Workspace (der vorgesehene Weg, nötig beim ersten Login)
sbx run --name solobox claude

# Symlinks für alles außer skills — /Users/DU ist dein HOST-Home, denn dort
# hängen die Ordner in der Sandbox; $HOME ist darin /home/agent.
sbx exec solobox bash -c 'for d in agents commands rules plugins hooks; do
  ln -sfn "/Users/DU/.claude/$d" "$HOME/.claude/$d"; done'

# Skills kopieren (NICHT verlinken — siehe unten)
sbx exec solobox bash -c '
  ( cd /Users/DU/.claude/skills && tar cf - . ) \
  | ( mkdir -p "$HOME/.claude/skills" && cd "$HOME/.claude/skills" && tar xf - --no-same-permissions )'

sbx ls                    # alle Sandboxes der Maschine
sbx policy ls solobox     # Netzregeln dieser Sandbox
sbx mcp ls                # registrierte MCP-Server
sbx stop solobox          # anhalten (Zustand bleibt)
sbx rm --force solobox    # entfernen (Zustand weg)
```

## Safe Chain (Malware-Schutz vor der Installation)

```bash
# greift der Schutz?
sbx exec solobox bash -lc 'command -v npm; type -t npm'
# /opt/safe-chain/shims/npm   und   file

# Scharftest mit dem offiziellen Testpaket
sbx exec solobox bash -lc 'cd /tmp && mkdir -p sc && cd sc && npm init -y >/dev/null && npm install safe-chain-test'
# ✖ Safe-chain: Malicious changes detected

# abschalten, wenn er im Weg steht
export SOLOBOX_SAFE_CHAIN=0
```

⚠️ Immer eine Shell dazwischen: `sbx exec solobox npm …` umgeht
`/etc/sandbox-persistent.sh` und damit den `PATH`. Richtig ist
`sbx exec solobox bash -lc 'npm …'`.

## Netz

```bash
sbx policy allow network --sandbox solobox '*.example.com'   # sofort
# dauerhaft: EXTRA_HOSTS in ~/.config/solobox/solobox.conf
```

Immer `--sandbox`. Eine globale Regel würde die anderen Sandboxes dieser Maschine
mitverändern — `sbx ls` zeigt, wie viele das sind.

## Konfiguration (optional)

`~/.config/solobox/solobox.conf`, Vorlage: `solobox/solobox.conf.example`

```bash
ROOTS=("$HOME/dev")                         # ⚠️ nur beim Anlegen, nur Verzeichnisse
EXTRA_HOSTS=('*.googleapis.com')
MCP_SERVERS=(linear)
HOOK_SKIP=(Notification Stop)               # leer = alle Hooks übernehmen
ISOLATE_SKILLS=0                            # 1 = eigener Skill-Store
```

## Die drei Dinge, die man hier falsch macht

**1. Claude im Primary Workspace starten und dann `cd`.**
Projektlokale `CLAUDE.md`, `.claude/` und `.mcp.json` werden beim **Start**
gelesen. `cd` in der laufenden Sitzung holt das nicht nach. Immer im Projekt
starten — dafür ist `solobox up` da.

**2. `skills` verlinken.**
`/home/agent/.claude/skills` ist der Skill-Store von sbx, den sich alle
Sandboxes teilen. Ein `ln -sfn` dorthin scheitert nicht, sondern legt den Link
**hinein**. Skills werden kopiert.

**3. Nach `solobox update` erwarten, dass die Sandbox das neue Image hat.**
Tut sie nicht. Container werden beim Anlegen aus dem Template kopiert, nicht
laufend angeglichen. `solobox rm && solobox up` — und der Login ist weg.

## Was `rm` kostet

- den Claude-Login
- zur Laufzeit installierte Pakete
- Änderungen an `/etc/sandbox-persistent.sh`

**Nicht** betroffen: deine Projektdateien. Die liegen auf dem Host.

## Unterschiede zu devbox auf einen Blick

|                       | devbox                         | solobox                 |
| --------------------- | ------------------------------ | ----------------------- |
| Aufruf                | `./devbox/devbox.sh up privat` | `solobox up` im Projekt |
| Sandboxes             | eine pro Profil                | genau eine              |
| Conf                  | Pflicht                        | optional                |
| Skills/Agents global  | über `SHARE_ALL`               | immer                   |
| Hooks aus `~/.claude` | nein                           | ja, gefiltert           |
| Startordner           | Primary Workspace              | das aktuelle Projekt    |

## Wenn etwas klemmt

- [troubleshooting.md](troubleshooting.md)
- [Tutorial](tutorial-solo/README.md)
- [architektur.md](architektur.md)
