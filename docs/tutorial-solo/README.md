# Tutorial — solobox: eine einzige Sandbox

Dies ist die **zweite Variante** in diesem Repo. Die erste (`devbox`) baut dir
mehrere Sandboxes nach Profilen. Diese hier baut dir **genau eine** — für alle
Projekte, mit deiner kompletten globalen Claude-Konfiguration darin.

| | devbox (Variante 1) | solobox (Variante 2) |
|---|---|---|
| Anzahl Sandboxes | eine pro Profil | genau eine |
| Aufruf | `./devbox/devbox.sh up privat` | `solobox up` — im Projekt |
| Konfigurationsdatei | Pflicht | optional |
| Globale Skills/Agents | pro Profil zuschaltbar | immer dabei |
| Globale Hooks & Plugins | nur über `SHARE_ALL` | immer dabei, gefiltert |
| Projektlokale Ergänzungen | ja | ja |

## Setzt Variante 1 voraus?

**Zum Lesen ja, zum Ausführen nein.** Dieses Tutorial erklärt nicht noch einmal,
wie man `sbx` installiert, ein Dockerfile schreibt, ein Image in den
Template-Store lädt oder Netzregeln setzt. Das steht im devbox-Tutorial:

- [Kapitel 0 — Vorbereitung](../tutorial/00-vorbereitung.md) (Installation, auch Windows/WSL2)
- [Kapitel 1 — Nackt starten](../tutorial/01-nackt-starten.md)
- [Kapitel 2 — Ein eigenes Dockerfile](../tutorial/02-eigenes-dockerfile.md)
- [Kapitel 3 — Bauen und laden](../tutorial/03-bauen-und-laden.md)
- [Kapitel 4 — Netz und Safe Chain](../tutorial/04-netz-und-safe-chain.md)

Wer das gelesen hat, kann hier direkt einsteigen.

## Die Kapitel

| #   | Kapitel                                                     | Danach kannst du                                                  |
| --- | ----------------------------------------------------------- | ----------------------------------------------------------------- |
| 0   | [Warum eine statt viele](00-warum-eine.md)                   | das Image bauen und weißt, was daran anders ist                    |
| 1   | [Die eine Sandbox](01-die-eine-sandbox.md)                   | Claude direkt im Projekt starten — ohne neue Sandbox               |
| 2   | [Globale Konfiguration](02-globale-config.md)                | deine Skills und Agents überall haben, ohne sie zu kopieren        |
| 3   | [Hooks, Plugins, Settings](03-hooks-plugins-settings.md)     | erklären, warum ein Host-Hook im Container scheitert               |
| 4   | [MCP-Server](04-mcp.md)                                      | Plugin-Server und OAuth-Server in die Sandbox bringen              |
| 5   | [Projektlokale Ergänzungen](05-projektlokal.md)              | nachweisen, dass global und projektlokal gleichzeitig gelten       |
| 6   | [Der Wrapper](06-der-wrapper.md)                             | das Ganze auf `solobox up` reduzieren                              |

Jedes Kapitel endet in einem **lauffähigen Zustand**.

## Was du brauchst

```bash
sbx version      # v0.38 oder neuer
docker --version # der LOKALE Docker — zusätzlich zu sbx
git --version
```

Plattenplatz: das Image belegt rund **5,9 GB**, beim Übertragen in den
`sbx`-Store entsteht kurzzeitig eine tar-Datei von etwa 1,4 GB. Rechne mit rund
8 GB frei.

> **Windows:** `solobox.sh` ist ein Bash-Skript und läuft nicht in PowerShell.
> Nutze WSL2 — die Einrichtung steht in
> [devbox-Kapitel 0](../tutorial/00-vorbereitung.md).

## Wenn du feststeckst

- [cheatsheet-solo.md](../cheatsheet-solo.md) — alle solobox-Kommandos auf einer Seite
- [troubleshooting.md](../troubleshooting.md) — die häufigen Fehler
- [architektur.md](../architektur.md) — warum es so gebaut ist
- Die Referenzdateien `solobox/Dockerfile`, `solobox/solobox.sh` und
  `solobox/solobox.conf.example` sind der Stand nach Kapitel 6.
