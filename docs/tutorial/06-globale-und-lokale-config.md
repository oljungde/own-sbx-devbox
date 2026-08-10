# Kapitel 6 — Globale und lokale Konfiguration

**Ziel:** Deine Skills, Agents und Commands sollen in der Sandbox verfügbar
sein — ohne sie in jedes Projekt zu kopieren.

**Am Ende dieses Kapitels:** Eine Sandbox, die deine globale Claude-Konfiguration
kennt und zusätzlich projektlokale Einstellungen berücksichtigt.

---

## Die Ausgangslage

Aus Kapitel 1 kennst du den Satz schon:

> Sandboxes do not inherit user-level configuration from the host machine, such
> as `~/.claude`. Only project-level configuration files located within the
> working directory are accessible inside the sandbox.

Das ist gut so — in `~/.claude` liegt auch deine `.credentials.json`. Aber es
heißt eben auch: deine sorgfältig gebauten Skills und Agents sind weg.

Der naheliegende Ausweg wäre, sie in jedes Projekt zu kopieren. Bei zwanzig
Projekten hast du dann zwanzig Kopien, die auseinanderlaufen. Das wollen wir
nicht.

## Der Weg: gezielt mounten

Wir hängen genau die Unterordner ein, die wir brauchen — read-only:

```bash
sbx create -t devbox/base:latest --name devbox-privat claude \
  ~/dev/own \
  ~/.claude/agents:ro \
  ~/.claude/skills:ro \
  ~/.claude/commands:ro \
  ~/.claude/rules:ro \
  ~/.claude/plugins:ro
```

Drei bewusste Entscheidungen dahinter:

**Gezielte Unterordner statt `~/.claude` komplett.** Sonst läge deine
`.credentials.json` im Container.

**`:ro` ist Pflicht.** Ohne Schreibschutz könnte ein Agent im Container deine
globalen Skills verändern — und die gelten dann auf dem Host für *alle* deine
Projekte. Das wäre ein Weg aus der Sandbox heraus.

**`settings.json` bleibt draußen.** Da stehen Berechtigungen für deinen Host
drin, die im Container nicht passen.

## Der Haken: der Pfad stimmt nicht

Extra-Workspaces landen unter ihrem **absoluten Host-Pfad**. Deine Skills liegen
in der Sandbox also unter `/Users/du/.claude/skills`.

Claude sucht sie aber unter `/home/agent/.claude/skills`.

Die Brücke ist ein Symlink:

```bash
sbx exec -d devbox-privat bash -c '
  mkdir -p "$HOME/.claude"
  for d in agents commands rules plugins; do
    ln -sfn "/Users/du/.claude/$d" "$HOME/.claude/$d"
  done
'
```

Der Wrapper in Kapitel 7 macht das automatisch und setzt den Host-Pfad richtig
ein.

Prüfen:

```bash
sbx exec -it devbox-privat bash -c 'ls -la ~/.claude'
```

Du solltest vier Symlinks sehen, die auf die gemounteten Pfade zeigen.

## ⚠️ Warum `skills` in der Schleife fehlt

Das ist kein Vertipper. Schau dir an, was `sbx create` beim Anlegen ausgibt:

```
skills  .../com.docker.sandboxes/sandboxes/agent-skills → /home/agent/.claude/skills
```

**`sbx` hängt an genau diesem Pfad seinen eigenen Skill-Store ein** — und zwar
denselben Store für *alle* Sandboxes auf der Maschine.

Das Tückische daran ist nicht, dass ein `ln -sfn` dorthin scheitert. Es scheitert
nämlich **nicht**. Es meldet Erfolg — und legt den Link *in* das eingehängte
Verzeichnis:

```
$ ln -sfn /Users/du/.claude/skills ~/.claude/skills
$ ls -la ~/.claude/skills/
lrwxrwxrwx  skills -> /Users/du/.claude/skills     # gelandet IM Store
```

Und weil dieser Store geteilt ist, läge dieser Eintrag damit auch in jeder
anderen Sandbox deines Rechners. Ein stiller Seiteneffekt über Sandbox-Grenzen
hinweg — genau das, was eine Sandbox verhindern soll.

Deshalb hat der Wrapper zwei getrennte Listen:

```bash
CLAUDE_SHARED=(agents skills commands rules plugins)   # wird gemountet
CLAUDE_LINKED=(agents commands rules plugins)          # wird verlinkt
```

und zusätzlich eine Sicherung, die abbricht, wenn das Ziel schon ein echtes
Verzeichnis ist:

```bash
if [ -d "$ziel" ] && [ ! -L "$ziel" ]; then
  echo "Hinweis: $ziel ist ein echtes Verzeichnis — uebersprungen." >&2
  continue
fi
```

**Was heißt das praktisch?** Deine globalen `skills` sind in der Sandbox
weiterhin **lesbar** — unter ihrem Host-Pfad `/Users/du/.claude/skills`. Sie
werden nur nicht automatisch als User-Skills gefunden. Wenn du einen davon
brauchst, kopiere ihn in `.claude/skills/` des Projekts. Das ist ohnehin der
sauberere Weg: dann ist er versioniert und alle im Team haben ihn.

## Wenn ein Ordner noch nicht existiert

`sbx create` bricht ab, wenn ein zu mountender Ordner nicht existiert. Gerade
`~/.claude/rules` fehlt auf frisch eingerichteten Rechnern oft. Deshalb legt der
Wrapper fehlende Ordner vorher an:

```bash
for d in agents skills commands rules plugins; do
  mkdir -p "$HOME/.claude/$d"
done
```

Klein, aber es entscheidet darüber, ob das Setup bei der Hälfte der Gruppe
abbricht.

## Der native Weg — und warum wir ihn nicht nehmen

`sbx` bringt selbst etwas mit:

```bash
sbx skills import      # kopiert u.a. aus ~/.claude/skills
```

Klingt einfacher. Drei Gründe, warum wir trotzdem mounten:

| | `sbx skills import` | Unser `:ro`-Mount |
|---|---|---|
| Aktualität | **Kopie** — nach jeder Änderung neu importieren | live |
| Schreibrechte | Store wird **read-write** gemountet | read-only |
| Umfang | nur `skills` | skills, agents, commands, rules, plugins |
| Stabilität | als **EXPERIMENTAL** markiert | stabile Flags |

Besonders die zweite Zeile — und die ist nachgemessen, nicht vermutet:

```bash
# in der Sandbox
touch ~/.claude/skills/probe     # funktioniert
```

Der Store ist beschreibbar **und geteilt**. Was du dort ablegst, sehen alle
anderen Sandboxes auf deinem Rechner — auch die, die zu ganz anderen Projekten
gehören.

Wenn du das trotzdem willst (es ist ja durchaus bequem):

```bash
sbx skills import
```

Aber triff die Entscheidung bewusst, nicht aus Versehen.

## Projektlokale Konfiguration

Das Schöne: Projektlokales funktioniert **von selbst**, weil es im gemounteten
Projektordner liegt.

```
mein-projekt/
├── .claude/
│   ├── settings.json      # Hooks, Berechtigungen für DIESES Projekt
│   ├── skills/            # projektspezifische Skills
│   └── agents/            # projektspezifische Agents
├── .mcp.json              # MCP-Server für DIESES Projekt
└── CLAUDE.md              # Projektanweisungen
```

Diese Dateien gehören **ins Repo**. Das ist der eigentliche Vorteil: Sie sind
versioniert, im Team geteilt, und jeder bekommt dieselbe Umgebung.

**Faustregel:**

| | Wo |
|---|---|
| Brauche ich in jedem Projekt | global, `~/.claude/`, gemountet |
| Gehört zu diesem einen Projekt | lokal, `.claude/` im Repo |

**Hooks** laufen übrigens **im Container**. Ein Hook, der ein Werkzeug aufruft,
das nur auf deinem Mac existiert, schlägt in der Sandbox fehl. Halte
projektlokale Hooks portabel.

## MCP-Server

Zwei Wege, mit klarer Arbeitsteilung:

**① Projektlokale `.mcp.json`** — der Standardweg. Liegt im Repo, wird
automatisch gefunden, ist versionierbar:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

Wichtig: Der Host, den der Server anspricht, muss in der Netzwerk-Policy stehen
(Kapitel 4) — sonst startet er, kommt aber nicht raus.

**② `sbx mcp` für Dienste mit OAuth-Login** — Atlassian, Linear, Notion und
Ähnliches. Deren Anmeldeflow im Container abzuwickeln ist mühsam. `sbx` betreibt
diese Server **außerhalb** der Sandbox und regelt die Anmeldung dort:

```bash
sbx mcp add linear --url https://mcp.linear.app/mcp
sbx mcp auth linear
sbx mcp load linear --sandbox devbox-privat
```

Registrierte Server ansehen: `sbx mcp ls`.

## Alles auf einmal — und was es kostet

Bis hierhin hat dieses Kapitel jede Trennung verteidigt: Skills nicht in den
geteilten Store, `settings.json` nicht mounten, MCP pro Projekt. Diese Trennungen
haben genau einen Grund — **andere Sandboxes auf derselben Maschine**.

Auf einem Rechner, auf dem nur deine eigenen Sandboxes laufen, gibt es dieses
Gegenüber nicht. Dann ist die Trennung Aufwand ohne Gegenwert, und du darfst sie
zurücknehmen. Wichtig ist nur: **bewusst**, nicht aus Versehen. Deshalb steht der
Schalter im Profil und nicht im Skript:

```bash
alles)
  NAME="alles"
  WORKSPACES=( "$HOME/dev/own" )
  EXTRA_HOSTS=( 'mcp.context7.com' )

  SHARE_ALL=1
  MCP_SERVERS=( linear )
  MCP_CONFIG="$HOME/.config/devbox/mcp.json"
  ;;
```

`SHARE_ALL=1` löst beim `up` zwei Schritte aus:

```bash
# 1. Skills in den geteilten Store kopieren
( cd "$HOST_HOME/.claude/skills" && tar cf - . ) \
  | ( cd ~/.claude/skills && tar xf - --no-same-permissions )

# 2. eine settings.json IN der Sandbox schreiben, die alle installierten
#    Plugins aktiviert — abgeleitet aus installed_plugins.json
```

**Warum `tar` und nicht `cp -r`?** Das sieht nach Angeberei aus, ist aber ein
gemessener Unterschied. Ist ein Skill-Ordner auf dem Host schreibgeschützt
(`555`, bei aus einem Repo ausgecheckten Skills nicht selten), legt `cp` das
Zielverzeichnis mit denselben Rechten an — und kann danach nichts mehr
hineinschreiben:

```text
cp: setting permissions for '.../mein-skill': Permission denied
```

Das liest sich wie eine Lappalie, aber der Skill ist danach **nicht** da. Und
`--no-preserve=mode` hilft nicht: Es gilt für Dateien, nicht für Verzeichnisse.
`tar` setzt die Verzeichnisrechte erst zum Schluss und schreibt deshalb sauber
hinein, auch beim zweiten und dritten `up`.

Die Lehre daraus ist allgemeiner als der Befehl: Ein Schritt, der bei **jedem**
Start läuft, muss zweimal hintereinander funktionieren. Teste ihn auch zweimal.

`MCP_SERVERS` und `MCP_CONFIG` bedienen die beiden Server-Arten von oben: die bei
`sbx mcp` registrierten (Weg ②) und die selbstgeschriebenen (Weg ①), letztere
nicht projektlokal, sondern für alle Projekte der Sandbox.

**Was du dafür aufgibst:**

| | mit `SHARE_ALL=1` |
|---|---|
| Skill-Store | read-write und mit **allen** Sandboxes der Maschine geteilt |
| Aktualität | Kopie — neue Skills und Plugins erst nach dem nächsten `up` |
| Plugin-Aktivierung | pauschal alle installierten, nicht projektweise ausgewählt |

**Was bleibt:** Die `settings.json` des Hosts wird weiterhin nicht gemountet. Die
Datei in der Sandbox wird *erzeugt* und enthält nur `enabledPlugins` — die
Host-Berechtigungen bleiben auf dem Host. Diese eine Trennung geben wir auch im
Bequemlichkeitsmodus nicht auf, weil sie nichts kostet.

Standard ist `SHARE_ALL=0`. Wer nichts einträgt, bekommt das Verhalten aus dem
Rest dieses Kapitels.

---

## Abnahme dieses Kapitels

```bash
sbx exec -it devbox-privat bash -c 'ls -la ~/.claude'   # Symlinks vorhanden
```

Und in einer Claude-Session in der Sandbox: Tauchen deine globalen Skills und
Agents auf? Wenn ja, ist das Kapitel geschafft.

### Zu `plugins`

Gute Nachricht: Der gemountete Ordner enthält bereits alles Nötige —

```bash
$ sbx exec devbox-privat bash -c 'ls ~/.claude/plugins/'
cache  data  installed_plugins.json  known_marketplaces.json  marketplaces
```

Die Registrierung (`installed_plugins.json`) kommt also mit.

Was **nicht** mitkommt, ist die *Aktivierung*: welche Plugins eingeschaltet sind,
steht in `settings.json` — und die mounten wir bewusst nicht (siehe oben). Willst
du ein gemountetes Plugin in der Sandbox nutzen, aktiviere es projektlokal:

```json
// <projekt>/.claude/settings.json
{
  "enabledPlugins": {
    "mattpocock-skills@claude-plugins-official": true
  }
}
```

Das passt zur Faustregel von eben: global liegt der Inhalt, lokal entscheidet
das Projekt, was davon gilt.

---

➡️ **Weiter mit [Kapitel 7 — Das Wrapper-Skript](07-wrapper-und-kit.md)**
