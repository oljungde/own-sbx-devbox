# Tutorial — devbox von Grund auf bauen

Sieben Kapitel. Jedes endet in einem **lauffähigen Zustand** — du kannst nach
jedem Kapitel aufhören und hast etwas, das funktioniert.

Du tippst alles selbst. Das ist Absicht: Am Ende gehört dir dein eigenes Repo,
und du weißt, was jede Zeile darin tut.

| # | Kapitel | Danach kannst du |
|---|---|---|
| 1 | [Nackt starten](01-nackt-starten.md) | eine Sandbox starten — und weißt, was ihr fehlt |
| 2 | [Ein eigenes Dockerfile](02-eigenes-dockerfile.md) | eine Bauanleitung für deine Toolchain schreiben |
| 3 | [Bauen und laden](03-bauen-und-laden.md) | dein Image bauen und eine Sandbox daraus starten |
| 4 | [Netz und Safe Chain](04-netz-und-safe-chain.md) | steuern, wohin die Sandbox telefoniert, und Malware abfangen |
| 5 | [Mehrere Projekte](05-mehrere-projekte.md) | alle Projekte in einer Sandbox haben |
| 6 | [Globale und lokale Config](06-globale-und-lokale-config.md) | deine Skills und Agents mitnehmen |
| 7 | [Wrapper und Kit](07-wrapper-und-kit.md) | das Ganze auf ein Kommando reduzieren |

## Vorbereitung

Auf dem Rechner gebraucht werden:

```bash
sbx version      # v0.38 oder neuer  -> https://docs.docker.com/ai/sandboxes/get-started/
docker --version
git --version
```

Rechne mit rund **8 GB freiem Plattenplatz**: Das Image belegt etwa 5,9 GB, und
beim Übertragen in den `sbx`-Store entsteht kurzzeitig eine tar-Datei von rund
1,4 GB (komprimiert).

## Wenn du feststeckst

- [troubleshooting.md](../troubleshooting.md) — die häufigen Fehler in der
  Reihenfolge, in der sie auftreten
- [architektur.md](../architektur.md) — warum devbox so gebaut ist
- Die Referenz-Dateien in diesem Repo (`devbox/Dockerfile`, `devbox/devbox.sh`)
  sind der Stand nach Kapitel 7. Vergleiche im Zweifel damit.
