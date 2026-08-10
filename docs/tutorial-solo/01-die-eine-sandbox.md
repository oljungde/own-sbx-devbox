# Kapitel 1 — Die eine Sandbox

**Ziel:** Eine Sandbox anlegen, die alle Projekte sieht — und Claude darin **im
jeweiligen Projekt** starten.

**Am Ende dieses Kapitels:** Eine laufende Sandbox `solobox`, in der du in jedem
deiner Projekte arbeiten kannst, ohne je eine zweite anzulegen.

---

## Die Ein-Weg-Entscheidung

`sbx` nimmt Workspaces **nur beim Anlegen** entgegen. An einer bestehenden
Sandbox lehnt es sie ab:

```bash
Error: existing sandbox ... can't be given new workspaces
```

Bei devbox war das unangenehm. Hier ist es _die_ Entscheidung des Kapitels, denn
es gibt keine zweite Sandbox, die den fehlenden Ordner nachreichen könnte. Der
einzige Ausweg wäre `sbx rm` und neu anlegen — und damit sind Login, installierte
Pakete und aller Zustand weg.

> 🎯 **Eine Dach-Wurzel, nicht einzelne Projekte.**

```bash
sbx create -t solobox/base:latest --name solobox claude ~/dev
```

Alles unter `~/dev` ist damit für immer dabei — auch das Projekt, das du morgen
anlegst. Liegt bei dir Berufliches unter `~/dev/work` und Privates unter
`~/dev/own`, deckt diese eine Zeile beides ab.

- Der **erste** Pfad ist der _Primary Workspace_ — dort landet der Agent, wenn er
  ohne Zielverzeichnis startet.
- Alle **weiteren** Pfade werden unter ihrem **absoluten Host-Pfad** eingehängt.
  Das ist gleich der Schlüssel zum zweiten Teil dieses Kapitels.

## ⚠️ Nur Verzeichnisse

Der naheliegende nächste Schritt wäre, die Git-Identität mitzunehmen:

```bash
sbx create -t solobox/base:latest --name solobox claude ~/dev ~/.gitconfig:ro
```

Das scheitert:

```bash
ERROR: workspace path exists but is not a directory: /Users/du/.gitconfig
```

`sbx` hängt **Verzeichnisse** ein, keine einzelnen Dateien. Für eine Datei gibt
es `sbx cp` — oder, im Fall von git, den saubereren Weg: nur die zwei Werte
setzen, auf die es ankommt.

```bash
sbx exec solobox git config --global user.name  "$(git config --global --get user.name)"
sbx exec solobox git config --global user.email "$(git config --global --get user.email)"
```

Das ist nicht nur ein Ausweichmanöver, sondern besser: eine echte `~/.gitconfig`
enthält oft Aliase, `includeIf`-Blöcke und Pfade zu Credential-Helfern des
Hosts, die im Container ins Leere zeigen. Der Wrapper erledigt genau diese zwei
Zeilen bei jedem `up` (`apply_git_identity`).

Ohne sie committet der Agent ohne Autor — oder git verweigert den Commit ganz.

## Der erste Start

```bash
sbx run --name solobox claude
```

Hier meldest du dich einmal bei Claude an. Der Login lebt **in** der Sandbox und
überlebt Stoppen und Starten — aber nicht das Entfernen.

Danach: `/exit`.

## Das Problem, das eine Sandbox mit sich bringt

Du bist gestartet, aber du bist im Primary Workspace — also in `~/dev`, nicht in
deinem Projekt. Der naheliegende Reflex ist, in der laufenden Sitzung ins Projekt
zu wechseln:

```bash
cd ~/dev/own/mein-projekt
```

**Das reicht nicht.** Claude Code liest die projektlokale Konfiguration —
`CLAUDE.md`, `.claude/`, `.mcp.json` — **beim Start** aus dem Arbeitsverzeichnis.
Ein `cd` in der laufenden Sitzung holt das nicht nach. Du sitzt dann in deinem
Projekt, aber ohne dessen Regeln.

## Die Lösung: im Projekt starten, ohne neue Sandbox

`sbx exec` kennt ein Arbeitsverzeichnis:

```bash
sbx exec -it -w ~/dev/own/mein-projekt solobox claude
```

Und weil zusätzliche Workspaces unter ihrem absoluten Host-Pfad eingehängt sind,
ist der Pfad auf dem Host **derselbe** wie in der Sandbox. Daraus wird ein
Einzeiler, der immer stimmt:

```bash
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude
```

Das ist der Kern dieser Variante. Eine Sandbox, viele Projekte, und der Start
findet trotzdem im richtigen Ordner statt.

## ⚠️ Prüfschritt: ist `exec` genauso vollwertig wie `run`?

`sbx run` ist der von `sbx` **vorgesehene** Weg, einen Agenten zu starten.
`sbx exec` startet einfach ein Kommando im Container. Das _sollte_ dasselbe sein
— aber „sollte" ist keine Grundlage. Prüfe es einmal selbst, es dauert zwei
Minuten:

```bash
# Variante A — der vorgesehene Weg
sbx run --name solobox claude
```

In der Sitzung eintippen und die Ausgaben merken oder abschreiben:

```bash
/status
/mcp
```

Dann `/exit`, und dasselbe über den anderen Weg:

```bash
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude
```

Wieder `/status` und `/mcp`.

**Erwartet:** dieselben MCP-Server, dasselbe Modell, dieselbe Version — nur das
Arbeitsverzeichnis unterscheidet sich.

### Das Ergebnis der Messung

Nachgemessen mit `sbx exec -w … solobox claude mcp list`:

```bash
plugin:grepika:grepika: npx -y @agentika/grepika@latest --mcp - ✔ Connected
claude.ai Google Calendar: … - ✔ Connected
mcp-gateway: http://mcp-gateway.docker.internal/mcp (HTTP) - ✔ Connected
```

Die entscheidende Zeile ist die letzte. Das **MCP-Gateway von `sbx`** — der
Kanal, über den `sbx mcp load` Server hineinreicht — ist auch über `sbx exec`
verbunden. Es wird also nicht von `sbx run` beim Start eingerichtet, sondern
steht in der Konfiguration der Sandbox und gilt für jede Sitzung darin.

Damit ist der Weg über `-w` tragfähig. Sollte bei dir doch etwas fehlen, ist der
Rückfallweg: `sbx run` zum Starten benutzen und die Sandbox mit dem Projekt als
Primary Workspace anlegen — dann geht allerdings die Idee „eine Sandbox für
alles" verloren.

Praktischerweise ist `claude mcp list` auch die schnellste Diagnose überhaupt:
sie läuft ohne interaktive Sitzung und ohne Modellaufruf.

## Ausprobieren

```bash
# ein neues Projekt auf dem HOST anlegen
mkdir -p ~/dev/own/brandneu && echo "hallo" > ~/dev/own/brandneu/test.txt

# ... und sofort darin arbeiten, ohne irgendetwas neu zu bauen
cd ~/dev/own/brandneu
sbx exec -it -w "$PWD" solobox bash
```

In der Sandbox:

```bash
pwd                 # /Users/du/dev/own/brandneu — derselbe Pfad wie auf dem Host
cat test.txt        # hallo
python --version    # Python 3.12.x
```

## Was passiert, wenn du außerhalb der Wurzel startest?

```bash
cd /tmp
sbx exec -it -w "$PWD" solobox claude
```

`/tmp` existiert im Container zwar, hat aber mit deinem Host-`/tmp` nichts zu
tun. Der Agent sitzt dann in einem Ordner, den du auf dem Host nicht siehst.
Der Wrapper in Kapitel 6 fängt genau das ab und sagt es dir, statt dich still
woanders landen zu lassen.

---

➡️ **Weiter mit [Kapitel 2 — Globale Konfiguration](02-globale-config.md)**
