# Kapitel 0 — Vorbereitung

Bevor wir irgendetwas bauen: zwei Prüfungen und eine einmalige Einrichtung.

## Zwei Dinge, die beide „Docker" heissen

Das verwechselt man am Anfang, und dann sucht man an der falschen Stelle:

- **Docker Desktop** mit seinem Daemon baut Images. `docker build` redet mit ihm.
- **Docker Sandboxes** (`sbx`) betreibt die Sandboxes. Es hat einen **eigenen
  Image-Store**, getrennt von Docker Desktop.

Aus dem zweiten Punkt folgt der Umweg, der in Kapitel 2 alle überrascht: ein
lokal gebautes Image muss als Tarball in den sbx-Store hinüber.

## Prüfen

```bash
sbx version          # nicht --version, das kennt sbx nicht
docker version
```

`sbx --version` gibt `ERROR: unknown flag: --version`. Das ist kein Defekt,
sondern eine Stolperstelle beim Skripten.

## Die globale Netz-Policy einmalig setzen

`sbx` verlangt eine Grundentscheidung, bevor die erste Sandbox startet:

```bash
sbx policy ls        # steht hier schon etwas, ist es getan
sbx policy init balanced
```

Zur Wahl stehen `deny-all`, `balanced` und `allow-all`. `balanced` lässt
typischen Entwicklungsverkehr zu. Unsere eigenen Regeln kommen in Kapitel 3
**pro Sandbox** obendrauf.

> ⚠️ Wenn auf diesem Rechner schon ein anderes sbx-Setup läuft, fass die globale
> Policy nicht an. Sie gilt für alle Sandboxes, auch für fremde. Alles, was
> sbx-claude selbst freigibt, wird deshalb ausschliesslich mit `--sandbox`
> gesetzt.

## Optional, aber empfohlen

```bash
brew install terminal-notifier   # für die Meldungen aus Kapitel 6
brew install fswatch             # macht den Wächter sparsamer, nicht nötig
```

Ohne `terminal-notifier` fällt der Wächter auf `osascript` zurück. Ohne
`fswatch` schaut er alle zwei Sekunden nach — bei ein paar kleinen Dateien
kostet das nichts.

## Der GitHub-Token

Damit `git push` und `gh` in der Sandbox funktionieren:

```bash
gh auth token | sbx secret set github
```

sbx' Proxy setzt das Geheimnis in ausgehende Anfragen ein; laut Dokumentation
betritt es das Container-Dateisystem nie.

> ⚠️ Ein voller `gh`-Token darf schreiben, löschen und Workflows auslösen. In
> Kapitel 5 baust du Rückfragen für git — die sind damit eine **Bremse gegen
> Versehen, keine Grenze**. Wer eine engere Grenze will, hinterlegt einen
> feingranularen Token mit Leserechten; dann scheitert `push` strukturell und
> nicht erst an einer Musterliste.

## Was noch fehlt und wo es herkommt

Die Claude-Anmeldung. Auf dem Mac liegt sie im **Keychain**, es gibt also keine
Datei, die man in eine Sandbox einhängen könnte. Im Linux-Container liegt sie in
einem Volume, das dem eingebauten claude-Kit gehört — pro Sandbox eines. Bei
einer Box pro Projekt heisst das: **einmal `/login` pro Projekt**.

Das klingt nach Arbeit und ist der Grund für eine Entscheidung, die in Kapitel 1
begründet und in Kapitel 5 wichtig wird: `sbx-claude` benutzt `sbx run` **nie**.

## Geschafft

```bash
sbx version && docker version --format '{{.Server.Version}}' && sbx policy ls
```

Wenn diese drei Zeilen etwas ausgeben, geht es in
[Kapitel 1](01-eine-box-pro-projekt.md) weiter.
