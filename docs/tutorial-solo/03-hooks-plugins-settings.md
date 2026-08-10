# Kapitel 3 — Hooks, Plugins, Settings

**Ziel:** Deine globalen Hooks und Plugins in der Sandbox nutzen — und
verstehen, warum man `settings.json` **ableitet** statt sie einzuhängen.

**Am Ende dieses Kapitels:** Eine Sandbox mit deinen Plugins und deinen
sinnvollen Hooks, und eine Erklärung für den einen Hook, der scheitert.

---

## Warum `settings.json` nicht gemountet wird

```bash
grep -o '"[a-zA-Z]*"' ~/.claude/settings.json | sort -u | head -20
```

In dieser Datei steht dreierlei durcheinander:

1. **Was überall gilt** — `enabledPlugins`, `model`, `effortLevel`, `hooks`.
2. **Was nur für deinen Host gilt** — `permissions` mit Pfaden deines Rechners,
   ein kompletter `sandbox`-Block mit `allowRead`/`allowWrite`-Listen.
3. **Was nur für dein Gerät gilt** — `theme`, `voice`, `tui`.

Gruppe 2 in einen Container zu tragen, ist im besten Fall wirkungslos und im
schlechtesten verwirrend: Du liest dann Regeln, die sich auf Pfade beziehen, die
es dort gar nicht gibt. Deshalb: **ableiten**, nicht mounten.

## Die abgeleitete Datei

```bash
sbx cp ~/.claude/settings.json solobox:/tmp/host-settings.json

sbx exec solobox python3 - <<'PY'
import json, pathlib
host = json.loads(pathlib.Path("/tmp/host-settings.json").read_text())
ziel = pathlib.Path.home() / ".claude" / "settings.json"
cfg = json.loads(ziel.read_text()) if ziel.exists() else {}

for key in ("enabledPlugins", "extraKnownMarketplaces", "model", "effortLevel"):
    if key in host:
        cfg[key] = host[key]

# Hooks ohne die beiden Desktop-Benachrichtigungen — warum, siehe unten.
cfg["hooks"] = {k: v for k, v in host.get("hooks", {}).items()
                if k not in ("Notification", "Stop")}

cfg.setdefault("permissions", {})["defaultMode"] = "acceptEdits"

ziel.parent.mkdir(parents=True, exist_ok=True)
ziel.write_text(json.dumps(cfg, indent=2) + "\n")
print(json.dumps(cfg, indent=2)[:400])
PY
```

Drei Entscheidungen stecken darin:

**`enabledPlugins` und `extraKnownMarketplaces` gehören zusammen.** Ohne die
Marktplatz-Einträge weiß Claude in der Sandbox nicht, woher ein aktiviertes
Plugin stammt.

**`permissions.defaultMode` wird gesetzt, nicht kopiert.** In der Sandbox darf
Claude Dateien ohne Rückfrage ändern (`acceptEdits`) — dafür ist sie da.
Bewusst **nicht** `bypassPermissions`: `~/dev` ist echt eingehängt und
beschreibbar. Die Sandbox schützt deinen Host, nicht deine Projekte.

### ⚠️ Die Datei, die zweierlei behauptet

Sieh dir an, was in der Sandbox **schon vorher** in der Datei stand:

```bash
sbx exec solobox bash -lc 'jq -c "{defaultMode, bypassPermissionsModeAccepted}" ~/.claude/settings.json'
```

Vor der Ableitung:

```json
{ "defaultMode": "bypassPermissions", "bypassPermissionsModeAccepted": true }
```

Das schreibt das **Image** dorthin, und zwar auf die _oberste_ Ebene — während
der dokumentierte Schlüssel `permissions.defaultMode` heißt. Setzt man nur
letzteren, sagt die Datei anschließend zweierlei, und welche Angabe gewinnt,
steht nirgends.

Deshalb entfernt solobox die beiden Schlüssel des Images, sobald ein anderer
Modus als `bypassPermissions` gewünscht ist. Danach:

```json
{ "defaultMode": null, "bypassPermissionsModeAccepted": null }
```

und in `permissions.defaultMode` steht genau ein Wert.

Umstellbar über `PERMISSION_MODE` in der Konfiguration
(`acceptEdits`, `default`, `plan`, `bypassPermissions`).

> **Wie man das NICHT prüft:** `claude --print` setzt Berechtigungen gar nicht
> durch — dort läuft ein Bash-Aufruf selbst mit `--permission-mode default`
> durch. Ob Bash nachfragt, zeigt ausschließlich die interaktive Sitzung.

### Der zweite Grund, warum die Datei nicht immer gewinnt

Wer die erste Sitzung nach dem Anlegen misst, misst etwas anderes als er denkt.
Sieh nach, womit der Agent tatsächlich läuft:

```bash
sbx exec solobox bash -lc 'ps -eo pid,etime,args | grep [c]laude'
```

Nach einem Start über `sbx run`:

bash
457 20:08 claude --dangerously-skip-permissions

```bash

**`sbx run` startet den Agenten mit abgeschalteten Berechtigungen.** Das ist aus
Sicht von `sbx` konsequent — die Sandbox _ist_ dort die Grenze. Für die
`settings.json` heißt es: in dieser Sitzung ist sie gegenstandslos, egal was
darin steht.

Ein über `sbx exec … claude` gestarteter Agent bekommt dieses Flag **nicht**.
Genau deshalb unterscheiden sich die beiden Startwege von `solobox up`:

| Start                       | Kommando                                | Berechtigungen              |
| --------------------------- | --------------------------------------- | --------------------------- |
| erstmalig, nach dem Anlegen | `sbx run --name solobox claude`         | abgeschaltet (Flag von sbx) |
| jedes weitere Mal           | `sbx exec -it -w "$PWD" solobox claude` | wie in `settings.json`      |

Willst du die Rückfragen prüfen, beende die erste Sitzung und starte neu — sonst
misst du das Flag und nicht deine Einstellung.

### Und der dritte Grund: Claude bringt einen eigenen Sandkasten mit

Startet man neu, ohne das Flag, und bittet Claude um ein `date` über das
Bash-Tool — kommt **immer noch keine Rückfrage**. Diesmal liegt es weder am Flag
noch an der Datei, sondern daran, dass Claude Code in der Sandbox _seinen
eigenen_ Bash-Sandkasten betreibt und Befehle, die darin laufen, ohne Rückfrage
zulässt (`autoAllowBashIfSandboxed`).

Das ist keine Vermutung. Nachgemessen mit zwei Schreibversuchen aus einer
Sitzung, die in `~/dev/own` gestartet wurde:

```

A: touch /Users/du/dev/own/PROBE-A -> OK
B: touch /home/agent/PROBE-B -> FEHLER: Schreibzugriff außerhalb des
erlaubten Arbeitsverzeichnisses blockiert

````bash

> 🎯 **Die Bremse ist nicht die Rückfrage, sondern das Arbeitsverzeichnis.**
> Innerhalb des Ordners, in dem Claude gestartet wurde, arbeitet der Agent frei.
> Außerhalb wird er hart geblockt — nicht gefragt, geblockt.

Und damit schließt sich der Kreis zu Kapitel 1: Weil `solobox up` Claude **im
Projekt** startet, ist der Radius genau dieses Projekt. Startest du stattdessen
in `~/dev`, ist der Radius alle deine Projekte. Das ist der eigentliche
Sicherheitsgewinn dieser Variante — und er hängt an einem Arbeitsverzeichnis,
nicht an einer Einstellung.

**Was `PERMISSION_MODE` dann noch tut:** Es greift für alles, was der innere
Sandkasten nicht abdeckt — und es ist der Schalter, wenn du die Voreinstellung
des Images (`bypassPermissions`) bewusst zurückholen willst. Wer umgekehrt
_echte_ Rückfragen auch für sandkastenfähige Befehle will, schaltet die
Automatik ab, indem er in die abgeleitete `settings.json` aufnimmt:

```json
"sandbox": { "autoAllowBashIfSandboxed": false }
````

Das ist bewusst nicht die Voreinstellung: eine Rückfrage pro `ls` ist Reibung
ohne Gegenwert, solange der Radius ohnehin auf das Projekt begrenzt ist.

**Der `sandbox`-Block des Hosts bleibt draußen.** Eine Sandbox-Konfiguration in
einer Sandbox ist ein eigenes Fass.

## ⚠️ Der Hook, der scheitert — einmal live

Jetzt der Teil, den man gesehen haben sollte. Nimm die Hooks **vollständig**,
also auch `Notification` und `Stop`:

```bash
sbx exec solobox python3 - <<'PY'
import json, pathlib
host = json.loads(pathlib.Path("/tmp/host-settings.json").read_text())
ziel = pathlib.Path.home() / ".claude" / "settings.json"
cfg = json.loads(ziel.read_text())
cfg["hooks"] = host.get("hooks", {})
ziel.write_text(json.dumps(cfg, indent=2) + "\n")
print("alle Hooks aktiv:", ", ".join(sorted(cfg["hooks"])))
PY
```

Starte Claude, stelle eine kurze Frage, und warte, bis die Antwort fertig ist:

```bash
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude
```

Beim Abschluss der Antwort feuert der `Stop`-Hook. Auf deinem Mac schickt er
eine Desktop-Benachrichtigung. In einem Linux-Container passiert das:

```bash
osascript: command not found
```

und weil `notify.sh` mit `set -euo pipefail` läuft, endet der Hook mit einem
Fehlerstatus — Claude meldet ihn dir bei **jeder** Antwort.

Das ist die Lektion des Kapitels:

> 🎯 **Hooks sind nicht portabel.** Ein Hook, der Host-Werkzeuge aufruft
> (`osascript`, `terminal-notifier`, `open`, `pbcopy`), kann in einem Container
> nicht funktionieren. Ein Hook, der nur mit `jq` und der Hook-Eingabe arbeitet,
> läuft überall.

Sieh dir den Unterschied an deinen eigenen Hooks an:

```bash
jq '.hooks | keys' ~/.claude/settings.json
jq -r '.hooks.PreToolUse[0].hooks[0].command' ~/.claude/settings.json | head -c 200
```

Der `PreToolUse`-Hook (der `.env`-Zugriffe blockiert) liest sein JSON mit `jq`
und entscheidet selbst — er läuft in der Sandbox einwandfrei. Genau deshalb
steht `jq` im Dockerfile.

Also: die beiden Benachrichtigungs-Hooks weglassen. Der Wrapper nennt die Liste
`HOOK_SKIP` und hat `Notification` und `Stop` voreingestellt. Willst du eigene
Hooks ausnehmen, tragen sie sich dort ein.

> **Alternative, falls dir die Benachrichtigungen wichtig sind:** Mach
> `notify.sh` auf dem Host verträglich — eine Zeile am Anfang genügt:
>
> ```bash
> command -v osascript >/dev/null 2>&1 || command -v terminal-notifier >/dev/null 2>&1 || exit 0
> ```
>
> Dann darf `HOOK_SKIP=()` leer bleiben. Das ändert allerdings eine Datei
> außerhalb dieses Repos — deshalb ist es nicht der Standardweg.

## Plugins

Plugins sind read-only eingehängt und über `enabledPlugins` aktiviert. Prüfen:

```bash
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude
```

```bash
/plugin
```

Erwartet: dieselben Plugins wie auf dem Host, als installiert und aktiv.

## ⚠️ Prüfschritt: stört der read-only-Mount?

`~/.claude/plugins` ist schreibgeschützt eingehängt. Claude Code schreibt dort
aber gelegentlich hinein (Cache-Pflege, `.last_inuse_sweep`). Prüfe, ob das eine
Warnung bleibt oder ein Fehler wird:

1. Claude in der Sandbox starten und ein paar Minuten normal arbeiten. Erwartet:
   keine Meldung. Ein stiller Schreibfehler beim Cache-Sweep ist harmlos.
2. Bewusst provozieren:

    ```bash
    /plugin
    ```

    und versuchen, ein Plugin zu installieren. **Erwartet: das scheitert** — und
    zwar richtig so. Plugins installierst du auf dem **Host**, die Sandbox nutzt
    sie nur. Nach der Installation auf dem Host holt `solobox sync` sie in die
    laufende Sandbox.

**Wenn stattdessen bei jedem Start eine Fehlermeldung erscheint** oder Plugins
gar nicht erst laden: dann reicht read-only nicht, und der Ordner muss kopiert
statt gemountet werden (rund 84 MB pro Durchlauf). Trage das in
[troubleshooting.md](../troubleshooting.md) nach — im Wrapper wäre es eine
Änderung an genau einer Stelle: `plugins` aus `CLAUDE_SHARED` heraus und in
`copy_skills` mit hinein.

### Das Ergebnis der Messung

```bash
sbx exec solobox touch /Users/du/.claude/plugins/SCHREIBTEST
# touch: cannot touch '...': Read-only file system
```

Der Mount hält also, was er verspricht. Und er stört nicht: In mehreren
Sitzungen kam keine Fehlermeldung, alle fünf Plugins waren aktiv, und der
MCP-Server eines Plugins meldete sich verbunden:

```bash
plugin:grepika:grepika: npx -y @agentika/grepika@latest --mcp - ✔ Connected
```

> 🎯 **read-only reicht.** Plugins installierst du auf dem Host, die Sandbox
> nutzt sie. Der 84-MB-Kopierweg bleibt unnötig.

## Was du nach diesem Kapitel hast

```bash
sbx exec solobox cat '/home/agent/.claude/settings.json'
```

Eine Datei, die **nur** enthält, was in einem Container Sinn ergibt: deine
Plugins, dein Modell, deine portablen Hooks, und ein bewusst gesetzter
Berechtigungsmodus.

---

➡️ **Weiter mit [Kapitel 4 — MCP-Server](04-mcp.md)**
