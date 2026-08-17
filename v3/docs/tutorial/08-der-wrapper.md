# Kapitel 8 — Der Wrapper

Alles aus den Kapiteln 1 bis 7 in einem Kommando. Und ein Teil, den es von Hand
gar nicht gab: die Drift-Prüfung über **alle** Projekt-Sandboxes.

## Was der Wrapper ersetzt

Bisher hast du pro Projekt getippt:

```bash
sbx create -t sbx-claude/base:latest --name sbx-claude-api claude \
  ~/dev/own/api ~/.claude/agents:ro ~/.claude/commands:ro … 
for h in api.anthropic.com github.com …; do sbx policy allow network --sandbox … "$h"; done
sbx exec … ln -sfn …
sbx skills import
sbx cp ~/.claude/settings.json …:/tmp/… && sbx exec … python3 -c "…"
sbx exec … git config --global user.name …
sbx mcp load … --sandbox …
sbx exec -it -w ~/dev/own/api sbx-claude-api claude
```

Jetzt:

```bash
cd ~/dev/own/api && sbx-claude up
```

## Einrichten

```bash
chmod +x v3/sbx-claude.sh v3/hooks/*.sh
./v3/sbx-claude.sh install --watcher
sbx-claude doctor
```

`install` legt einen Symlink in `~/.local/bin` und richtet auf Wunsch den
LaunchAgent aus Kapitel 6 ein.

Optional, für eigene Werte:

```bash
mkdir -p ~/.config/sbx-claude
cp v3/sbx-claude.conf.example ~/.config/sbx-claude/sbx-claude.conf
```

## Die Kommandos

| Kommando | Wirkung |
| --- | --- |
| `up [pfad]` | Sandbox des Projekts sicherstellen, alles anwenden, Claude im Projekt starten |
| `sync [pfad]` | Netz, Symlinks, Skills, Settings, Git-Identität, MCP erneut anwenden |
| `check` | passt alles zusammen? Exitcode = Dringlichkeit |
| `status` | alle Projekt-Sandboxes mit Image-Stand und Projektpfad |
| `shell [pfad]` | `bash` in der Box des Projekts |
| `allow <host>` | Host einmalig freigeben |
| `build [--force]` | Image bauen und in den sbx-Store laden |
| `update` | neu bauen **und** sagen, welche Box veraltet ist |
| `rm [pfad\|--all]` | Box(en) entfernen |
| `watch` | Wächter im Vordergrund |
| `install [--watcher]` | Symlink, optional LaunchAgent |
| `doctor` | alles prüfen und benennen |

## Der erste Lauf

```bash
cd ~/dev/own/api
sbx-claude up
```

Was du sehen wirst: Projekt und Sandbox-Name, gegebenenfalls ein Bau, dann das
Anlegen, die Netzregeln, die Symlinks, den Skill-Import (mit der Rückfrage zum
maschinenweiten Flag), die abgeleitete `settings.json`, die Git-Identität — und
dann Claude im Projekt. Beim ersten Mal einmal `/login`.

## Die Drift-Prüfung — hier wichtiger als überall sonst

```bash
sbx-claude check; echo "Stufe: $?"
```

Fünf Prüfungen, und der Exitcode sagt, was zu tun ist:

| Stufe | Bedeutung | Abhilfe |
| --- | --- | --- |
| 0 | alles aktuell | nichts |
| 1 | Kleinigkeit | `sync` |
| 2 | Image veraltet | `update` |
| 3 | Sandbox passt nicht zur Konfiguration | `rm` und `up` — **kostet die Anmeldung** |

Geprüft wird:

1. **Image gegen Dockerfile** — über das Label `sbx-claude.dockerfile-sha`
2. **Template im sbx-Store** — die Merkdatei kann stimmen, während das Template
   fehlt (anderer Rechner, `sbx reset`, Handarbeit)
3. **Sandbox gegen Image** — über den Stempel *in* der Box, mit Notiz als Rückfall
4. **Mounts gegen Konfiguration** — Mengenvergleich mit `comm`
5. **Rückkanal** — ist der Ereignisordner da?

### ⚠️ Schritt 3 und das Problem der gestoppten Box

Der Stempel in der Box (`/etc/sbx-claude-stamp`) ist die gute Quelle: eine
beobachtete Tatsache, die nicht lügen kann. Sie ist aber nur lesbar, wenn die Box
**läuft** — `sbx exec` würde eine gestoppte Box sonst erst starten, und dann
bootet ein blosses `status` acht Container.

Bei einer Box pro Projekt sind die meisten gestoppt. Genau deshalb stand in einer
früheren Fassung dieses Kapitels an dieser Stelle „Sandbox läuft nicht — Stempel
nicht lesbar, übersprungen". Klingt harmlos, war aber der **Normalfall** — und
`up` lief danach mit einem veralteten Image weiter, ohne etwas zu sagen.

Deshalb notiert `provision` den Dockerfile-Hash beim Anlegen zusätzlich auf dem
Host. Die Regel ist:

| Lage | Auskunft aus | Ausgabe sagt |
| --- | --- | --- |
| Box läuft | Stempel **in** der Box | „Stempel in der Box gelesen" |
| Box gestoppt, Notiz da | Notiz vom Anlegen | „laut Notiz vom Anlegen" |
| Box gestoppt, keine Notiz | nichts | „Stand unbekannt" |

> 🎯 Die Beobachtung gewinnt immer, wenn es sie gibt — die Notiz kann fehlen oder
> von Hand verstellt sein. Und die Ausgabe sagt dazu, **woher** die Auskunft
> kommt. Eine Prüfung, die nicht verrät, wie sicher sie ist, ist die
> unangenehmere Sorte Prüfung.

Vorher gab es diesen Vergleich übrigens dreimal im Skript — in `check`, in
`status` und in `update`, mit drei leicht verschiedenen Formulierungen für
dasselbe. Jetzt steht er einmal in `sandbox_stand()`.

> 🎯 Der Wächter wird hier **nicht** geprüft, obwohl er zur Benachrichtigung
> gehört. Er ist Host-Zustand, keine Eigenschaft dieser Sandbox — und als er hier
> stand, stimmten die Stufen nicht mehr („Stufe 1, also `sync`" hilft gegen einen
> nicht laufenden Wächter gar nichts). Er gehört in `doctor`, und dort steht er.
> Eine Prüfung, die die falsche Abhilfe nennt, ist schlechter als keine.

> 🎯 Warum das hier mehr zählt als in einem Setup mit einer Sandbox: Ein neues
> Template erreicht bestehende Boxen **nie**. Bei zehn Projekten merkst du das
> ohne diese Prüfung monatelang nicht — du arbeitest schlicht mit einem alten
> Image weiter. Deshalb sagt `update` auch nicht nur „gebaut", sondern
> **benennt**, welche Box veraltet ist.

```bash
sbx-claude update
```

Es baut neu und listet danach jede Box mit ihrem Stand — inklusive der fertigen
Befehlszeile pro betroffenem Projekt:

```
>> Ein neues Template erreicht bestehende Sandboxes NICHT. Stand:
   sbx-claude-api      gestoppt  ÄLTERES Image, rm+up (Notiz)  /Users/du/dev/own/api
   sbx-claude-shop     läuft     Image aktuell                 /Users/du/dev/own/shop
!! Der Reihe nach:
!!   cd '/Users/du/dev/own/api' && sbx-claude rm && sbx-claude up
```

Und `up` selbst ist nicht stumm: Stellt es fest, dass das Image älter als das
Dockerfile ist (Stufe 2), **fragt** es, ob neu gebaut werden soll, statt nur zu
warnen. Die Reihenfolge dabei ist nicht beliebig — erst das Image, dann die
Sandbox dagegen prüfen. Umgekehrt legte man die Box neu an und sie hinge sofort
wieder am alten Image: zwei Neuanlagen samt zwei Anmeldungen für einen Vorgang.

## Beobachtete Tatsachen statt Merkzettel

Der Wrapper vertraut keiner Datei auf dem Host, wenn er eine Tatsache beobachten
kann:

| Frage | Woran er es erkennt |
| --- | --- |
| Ist das Image aktuell? | Label im Image, nicht die Merkdatei |
| Läuft die Box auf diesem Image? | Datei `/etc/sbx-claude-stamp` **in** der Box |
| Was ist eingehängt? | `sbx ls --json` |
| Ist der Store aktiv? | `sbx settings get feature.shareSkills` |
| Läuft der Wächter? | `launchctl list` bzw. `pgrep` |

Merkdateien gibt es nur, wo es keine beobachtbare Tatsache gibt: die
Pfad-Zuordnung für die Namenskollision und die bestätigten projektlokalen Hosts.

## Die Fallen im Skript, die es wert sind

Fünf Stellen, die anders aussehen, als man sie schreiben würde:

**1. Die Shell-Prüfung ist die erste ausführbare Zeile.** `sh sbx-claude.sh`
ignoriert die Shebang, und `/bin/sh` ist auf macOS eine Bash 3.2 im POSIX-Modus
ohne Prozess-Substitution. Der Abbruch sieht dann nach einem Tippfehler weit
hinten aus. Die Erkennung ist zweistufig: leeres `BASH_VERSION` **oder**
`shopt -qo posix` — unter `sh` ist `BASH_VERSION` nämlich gesetzt.

**2. `SCRIPT_PATH` löst Symlinks selbst auf.** Der Aufruf kommt über den Symlink
in `~/.local/bin`; ohne Auflösung sucht das Skript sein Dockerfile dort:
`shasum: /Users/du/.local/bin/Dockerfile: No such file or directory`.
`readlink -f` gibt es auf macOS nicht verlässlich, deshalb eine Schleife.

**3. `pruefe_stand` steht nie in einer Pipe.** Eine Pipe oder `$(…)` steckt die
Funktion in eine Subshell — dann ist die gesetzte Stufe beim Aufrufer wieder 0
und der Exitcode immer 0. Die Einrückung ist deshalb ein **Parameter**.

**4. Jede Pipeline mit `sbx` in einer Zuweisung braucht `|| true`.**
`sbx template ls` endet mit Exitcode 1, wenn man nicht bei Docker angemeldet ist.
Mit `set -euo pipefail` bricht das Skript sonst stumm ab.

**5. Prozess-Substitution statt Here-String.** `done <<< "$text"` legt eine
temporäre Datei an — und die ist nicht überall schreibbar. Gemessen beim Bauen
dieser Fassung: `cannot create temp file for here document`. Richtig ist
`done < <(printf '%s\n' "$text")`. Eine Pipe wäre auch falsch: Subshell.

## Und die eine Liste, die es nur einmal geben darf

`gewuenschte_mounts()` ist die **einzige** Quelle der Workspace-Liste.
`provision` legt danach an, `pruefe_stand` vergleicht dagegen. Wer eine zweite
Liste einführt, bricht den Drift-Check: er meldet dann ewig Unterschiede oder
übersieht echte.

## Prüfen, dass alles zusammenpasst

```bash
sbx-claude doctor
sbx-claude status
cd ~/dev/own/api && sbx-claude check; echo "Stufe: $?"
```

## Und jetzt?

- [Cheatsheet](../cheatsheet.md) für den Alltag
- [Fehlersuche](../troubleshooting.md), wenn etwas klemmt
- [Architektur](../architektur.md) für die Begründungen — inklusive dessen, was
  diese Variante bewusst aufgibt
