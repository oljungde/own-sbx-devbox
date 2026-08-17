# Kapitel 1 — Eine Box pro Projekt

Wir legen von Hand an, was der Wrapper später automatisch tut. Nur so siehst du,
welche `sbx`-Kommandos darunter stecken — und warum eines davon nicht vorkommt.

## Die Idee in einem Bild

```
        v3/Dockerfile
             |  docker build + docker save + sbx template load
             v
      sbx-claude/base:latest          (EIN Image)
        /        |        \
       v         v         v
  sbx-claude-api  sbx-claude-shop  sbx-claude-devbox   (VIELE Sandboxes)
       |               |                |
    ~/dev/own/api  ~/dev/own/shop   ~/dev/own/devbox    (je ein Projekt)
```

Ein Image, viele Boxen. `-t/--template` ist nur eine Image-Referenz — nichts
bindet ein Image an eine Sandbox.

## Vorübung mit dem Standard-Image

Solange unser eigenes Image noch nicht existiert, nimm das mitgelieferte:

```bash
mkdir -p ~/dev/own/probe-api && cd ~/dev/own/probe-api && git init
sbx create --name sbx-claude-probe-api claude "$PWD"
sbx ls
```

`sbx ls` zeigt die Box, ihren Zustand und ihren Workspace.

## Der Name ist die Handhabe

`--name` ist nicht Kosmetik: der Name ist überall der Griff — `sbx exec NAME`,
`sbx policy allow network --sandbox NAME`, `sbx rm NAME`, `sbx cp NAME:PATH`.

Erlaubt sind Buchstaben, Ziffern, `-`, `.` und `+`. **Kein Unterstrich.** Ein
Projekt namens `foods_are_food` muss also umbenannt werden — der Wrapper macht
daraus `sbx-claude-foods-are-food`.

Wir setzen den Namen selbst statt sbx' Standard `<agent>-<workdir>` zu nehmen,
weil das gemeinsame Präfix `sbx-claude-` später alles trägt: Auflisten,
Aufräumen, den Drift-Check. Fremde Sandboxes auf derselben Maschine werden so
nie angefasst.

> 🎯 Der Name wird aus der **Git-Wurzel** gebildet, nicht aus dem aktuellen
> Verzeichnis. Sonst bekämen `projekt/`, `projekt/src/` und `projekt/test/` je
> eine eigene Box — drei Sandboxes und drei Anmeldungen für ein Repo.

Zwei Projekte können gleich heissen (`~/dev/own/api` und `~/dev/work/api`). Der
Wrapper merkt sich pro Name den Pfad und hängt bei einer Kollision sechs Zeichen
aus dem Pfad-Hash an: `sbx-claude-api+3f9c1d`.

## Starten — und das Kommando, das wir nicht nehmen

Es gibt zwei Wege, Claude in einer Sandbox zu starten:

```bash
sbx run --name sbx-claude-probe-api claude          # NICHT dieser
sbx exec -it -w "$PWD" sbx-claude-probe-api claude  # dieser
```

> ⚠️ **Die wichtigste Messung dieses Kapitels.** `sbx run` startet den Agenten
> mit `--dangerously-skip-permissions` — in der Schwestervariante `solobox` mit
> `ps` in der Sandbox nachgemessen. Dein Berechtigungsmodus ist in dieser
> Sitzung also wirkungslos.
>
> In einem Setup mit **einer** Sandbox ist das ein einmaliges Ärgernis beim
> allerersten Start. Bei **einer Box pro Projekt** wäre es der Normalfall: jedes
> neue Projekt beginnt mit einer Sitzung ohne Berechtigungsgrenzen.
>
> Deshalb benutzt `sbx-claude` `sbx run` **nie**, auch nicht beim Anlegen.
> `sbx exec -it` startet Claude genauso, und `/login` funktioniert darin: Claude
> gibt eine URL aus, du öffnest sie auf dem Mac und klebst den Code zurück.

Probier es aus:

```bash
sbx exec -it -w "$PWD" sbx-claude-probe-api claude
```

Melde dich mit `/login` an und frag etwas Kleines. Dann `/exit`.

## Warum `-w` nicht verhandelbar ist

Claude Code liest `CLAUDE.md`, `.claude/` und `.mcp.json` beim **Start** aus dem
Arbeitsverzeichnis. Ein `cd` in der laufenden Sitzung holt das nicht nach. Ohne
`-w` startet Claude im Primary Workspace und übersieht die projektlokale
Konfiguration — ohne eine Fehlermeldung. Das ist der unangenehmste Fehler in
diesem Aufbau, weil nichts kaputt aussieht.

## Prüfschritt: teilt sich das Image?

Zweite Box, dasselbe Image:

```bash
mkdir -p ~/dev/own/probe-shop && cd ~/dev/own/probe-shop && git init
sbx create --name sbx-claude-probe-shop claude "$PWD"
sbx inspect sbx-claude-probe-api  | grep -i image
sbx inspect sbx-claude-probe-shop | grep -i image
```

Gleicher Image-Digest, getrennte Container, getrennte Workspaces, getrennte
Policy- und Geheimnis-Bereiche. Genau das war das Ziel.

## Was das kostet

Was du mit dieser Aufteilung bezahlst, in aller Deutlichkeit:

| Aufwand | Wie oft |
| --- | --- |
| `/login` | einmal pro Projekt |
| Sandbox anlegen | einmal pro Projekt |
| Image neu bauen | einmal für alle |
| Nach neuem Image: `rm` + `up` + `/login` | **pro Projekt** |

Die letzte Zeile ist der Grund, warum das Dockerfile in Kapitel 2 voll
ausgestattet ist. Nachrüsten kostet hier N Neuanlagen, nicht eine.

## Aufräumen

```bash
sbx rm --force sbx-claude-probe-api sbx-claude-probe-shop
```

Weiter mit [Kapitel 2](02-eigenes-dockerfile.md).
