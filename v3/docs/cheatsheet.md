# Cheat Sheet — sbx-claude

## Von Null bis ins Projekt

```bash
# einmal pro Rechner
sbx policy init balanced                     # nur wenn noch keine Policy existiert
gh auth token | sbx secret set github        # damit push und gh funktionieren
chmod +x v3/sbx-claude.sh v3/hooks/*.sh
./v3/sbx-claude.sh install --watcher
./v3/sbx-claude.sh build                     # Chromium ist dabei, dauert

# einmal pro Projekt
cd ~/dev/own/mein-projekt
sbx-claude up                                # dann einmal /login
```

## Täglich

```bash
cd ~/dev/own/mein-projekt && sbx-claude up
```

Das ist alles. `up` findet die Git-Wurzel selbst, egal in welchem Unterordner du
stehst, und startet Claude dort.

## Wenn sich auf dem Host etwas geändert hat

| Was du geändert hast | Was du brauchst |
| --- | --- |
| neuer Skill, Agent, Command, Rule | `sbx-claude sync` |
| Plugin installiert oder aktualisiert | `sbx-claude sync` |
| `sbx-claude.conf` bearbeitet | `sbx-claude sync` |
| neuer Host in `EXTRA_HOSTS` | `sbx-claude sync` |
| `Dockerfile` bearbeitet | `sbx-claude update`, dann pro Projekt `rm` + `up` |
| `ROOTS`/Mounts sollen anders sein | `sbx-claude rm` + `up` (**kostet die Anmeldung**) |

Unsicher? Fragen statt raten:

```bash
sbx-claude check; echo "Stufe: $?"   # dieses Projekt
sbx-claude status                     # alle Projekte auf einen Blick
```

`up` fragt von selbst, wenn das Image älter als das Dockerfile ist, und bietet
danach das Neuanlegen der Sandbox an. Bei einer **gestoppten** Box kommt die
Auskunft aus der Notiz vom Anlegen und ist mit `(Notiz)` markiert — der Stempel in
der Box wird nur gelesen, wenn sie läuft, sonst würde `status` jede Box starten.

| Stufe | Bedeutung | Abhilfe |
| --- | --- | --- |
| 0 | alles aktuell | nichts |
| 1 | Kleinigkeit | `sync` |
| 2 | Image veraltet | `update` |
| 3 | Sandbox passt nicht | `rm` + `up` |

## Die Kommandos

```bash
sbx-claude up [pfad]          # Sandbox sicherstellen und Claude starten
sbx-claude sync [pfad]        # Konfiguration erneut anwenden, ohne Start
sbx-claude check              # Drift-Prüfung, Exitcode = Dringlichkeit
sbx-claude status             # alle Projekt-Boxen mit Image-Stand und Pfad
sbx-claude shell [pfad]       # bash in der Box
sbx-claude allow <host>       # Host einmalig freigeben
sbx-claude build [--force]    # Image bauen und laden
sbx-claude update             # neu bauen + sagen, welche Box veraltet ist
sbx-claude rm [pfad|--all]    # Box(en) entfernen
sbx-claude watch              # Wächter im Vordergrund
sbx-claude install [--watcher]
sbx-claude doctor
```

## Die rohen sbx-Kommandos dahinter

```bash
# Anlegen (Mounts NUR hier setzbar)
sbx create -t sbx-claude/base:latest --name sbx-claude-api claude \
  ~/dev/own/api ~/.claude/agents:ro ~/.local/state/sbx-claude/events

# Starten — im Projekt, und bewusst NICHT `sbx run`
sbx exec -it -w ~/dev/own/api sbx-claude-api claude

# Netz (immer mit --sandbox!)
sbx policy allow network --sandbox sbx-claude-api "api.example.com,*.cdn.example.com"
sbx policy ls sbx-claude-api
sbx policy ls --wide
sbx policy log sbx-claude-api
sbx policy check network --sandbox sbx-claude-api api.anthropic.com

# Image
docker build -t sbx-claude/base:latest -f v3/Dockerfile v3/
docker save sbx-claude/base:latest -o /tmp/i.tar
sbx template load /tmp/i.tar
sbx template ls

# Skills (maschinenweiter Store!)
sbx settings get feature.shareSkills --json
sbx settings set feature.shareSkills true
sbx skills import --dry-run
sbx skills import --force

# MCP
sbx mcp add linear --url https://mcp.linear.app/mcp
sbx mcp auth linear
sbx mcp load linear --sandbox sbx-claude-api
sbx mcp ls

# Geheimnisse
gh auth token | sbx secret set github
sbx secret ls

# Aufräumen und nachsehen
sbx ls
sbx ls --json
sbx inspect sbx-claude-api
sbx stop sbx-claude-api
sbx rm --force sbx-claude-api
sbx cp datei.txt sbx-claude-api:/home/agent/
```

> `sbx version`, nicht `sbx --version`. Und `sbx start` gibt es nicht — `sbx exec`
> startet eine gestoppte Box selbst.

## Berechtigungen und git

```bash
# so sieht die abgeleitete Datei in der Box aus
sbx exec sbx-claude-api cat ~/.claude/settings.json
```

| Was du tippst | Was passiert |
| --- | --- |
| `git status`, `log`, `diff` | läuft durch |
| `git commit`, `push`, `reset` … | **Rückfrage** |
| `git -C sub commit` | **Rückfrage** (deshalb `git *VERB*` als Muster) |
| `cd x && git push` | **Rückfrage** (Regeln greifen pro Segment) |
| `x=$(git push)` | **Rückfrage** (auch in Substitution) |
| `bash -c "git push"` | **Rückfrage** — wegen `Bash(bash -c *)` |
| `npm run release` (pusht intern) | läuft durch — nicht erkennbar |
| `echo x > .git/config` | läuft durch — bewusst aufgegeben |
| `rm -rf`, `sudo`, `curl \| sh` | **Rückfrage** |
| alles andere | läuft durch |

Wer prüfen will, ob Regeln wirklich auf jedes Segment greifen, braucht keine
Sandbox — eine `deny`-Regel genügt, die man ohnehin hat:

```bash
# mit deny: ["Bash(env)"] in der settings.json
cd /tmp && env          # muss blockiert werden -> Segmente werden ausgewertet
echo "$(env)"           # muss blockiert werden -> Substitution ebenso
```

## Benachrichtigung

```bash
sbx-claude watch                              # zum Zuschauen
sbx-claude install --watcher                   # dauerhaft
launchctl list | grep sbx-claude
tail -f ~/.local/state/sbx-claude/watch.log
ls -la ~/.local/state/sbx-claude/events/       # kommen Ereignisse an?

# stimmen Pfad, Name und Schwelle im Hook-Aufruf?
sbx exec sbx-claude-api cat ~/.claude/settings.json | grep notify
```

| Ereignis | Wann |
| --- | --- |
| `Notification` | immer — Claude wartet auf dich (auch bei git) |
| `Stop` | nur ab `NOTIFY_SCHWELLE` Sekunden (Standard 60) |
| Glocke | immer |

## Safe Chain

```bash
# in der Sandbox
npm install safe-chain-test        # muss blockiert werden
timeout 60 npm install safe-chain-test   # muss AUCH blockiert werden
export SBX_CLAUDE_SAFE_CHAIN=0     # abschalten
```

Der zweite Befehl ist der eigentliche Test: mit Shell-Funktionen statt Shims ging
er nachweislich durch.

## Konfiguration (optional)

```bash
mkdir -p ~/.config/sbx-claude
cp v3/sbx-claude.conf.example ~/.config/sbx-claude/sbx-claude.conf
```

In der Vorlage stehen die fünf, die man wirklich ändert:

| Variable | Bedeutung | Standard |
| --- | --- | --- |
| `EXTRA_HOSTS` | zusätzliche Netz-Hosts für alle Projekte | leer |
| `NOTIFY_SCHWELLE` | Sekunden bis „fertig" gemeldet wird | `60` |
| `MCP_SERVERS` | eigenständige Server über sbx' Gateway | leer |
| `PERMISSION_MODE` | `bypassPermissions`, `acceptEdits`, `default`, `plan` | `bypassPermissions` |
| `ISOLATE_SKILLS` | `1` = geteilten Skill-Store nicht einhängen | `0` |

Fünf weitere kann man hier genauso setzen, sie werden aber praktisch nie
angefasst — ihre Begründung steht als Kommentar im Kopf von `v3/sbx-claude.sh`:

| Variable | Bedeutung | Standard |
| --- | --- | --- |
| `GIT_ASK_VERBEN` | welche git-Verben nachfragen | 36 schreibende |
| `EXTRA_ASK` | unumkehrbares ausserhalb von git | `rm -rf`, `sudo`, `bash -c`, … |
| `HOOK_UEBERNEHMEN` | Hook-Ereignisse vom Host | `PreToolUse` u. a. |
| `CLAUDE_SHARED` | was aus `~/.claude` `:ro` mitkommt | 6 Ordner |
| `CLAUDE_LINKED` | was davon verlinkt wird | dieselben 6 |

Projektlokal, im Repo:

```
# .sbx-claude-hosts — wird beim up angezeigt und einmal bestätigt
*.sentry.io
```

## Die vier Dinge, die man hier falsch macht

1. **`sbx run` benutzen.** Es startet Claude mit
   `--dangerously-skip-permissions`. `sbx exec -it -w` tut es nicht.
2. **Mounts nachträglich wollen.** Sie sind nur beim `create` setzbar. Alles
   andere kostet `rm` + `up` + `/login`.
3. **Der git-Bremse zu viel zutrauen.** Mit vollem Token ist sie ein Schutz gegen
   Versehen, keine Grenze.
4. **Den Wächter vergessen.** Ohne ihn kommt keine Meldung an, und nichts sieht
   kaputt aus. `sbx-claude doctor` sagt es.

## Was `rm` kostet

| Bleibt | Ist weg |
| --- | --- |
| deine Projektdateien (liegen auf dem Host) | die Claude-Anmeldung des Projekts |
| das Image und das Template | zur Laufzeit Installiertes |
| deine globale `~/.claude`-Konfiguration | die Sitzungshistorie |
| die bestätigten projektlokalen Hosts | die Netzregeln der Box |

## Wenn du am Repo selbst arbeitest

```bash
shellcheck v3/sbx-claude.sh v3/hooks/*.sh
bash -n v3/sbx-claude.conf.example
test -x v3/sbx-claude.sh
./scripts/check-links.sh
```
