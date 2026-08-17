# Tutorial — sbx-claude: eine Sandbox pro Projekt

Neun Kapitel. Am Ende hast du ein Setup, in dem jedes Projekt seine eigene
Claude-Sandbox hat, alle aus demselben Image — mit einer Benachrichtigung, die
im Container wirklich funktioniert, und mit Rückfragen genau dort, wo etwas
Unumkehrbares passiert.

Diese Variante steht für sich. Du brauchst weder `devbox/` noch `solobox/`
gelesen zu haben, und nichts von dort gilt hier automatisch.

## Die Kapitel

| # | Kapitel | Danach kannst du |
| --- | --- | --- |
| 0 | [Vorbereitung](00-vorbereitung.md) | prüfen, ob `sbx` und Docker bereit sind |
| 1 | [Eine Box pro Projekt](01-eine-box-pro-projekt.md) | von Hand eine Projekt-Sandbox anlegen und darin starten |
| 2 | [Ein eigenes Dockerfile](02-eigenes-dockerfile.md) | das gemeinsame Image bauen und in den sbx-Store bringen |
| 3 | [Netz](03-netz.md) | bestimmen, mit welchen Adressen die Box reden darf |
| 4 | [Globale Konfiguration](04-globale-config.md) | Agents, Commands, Rules, Plugins und Skills mitnehmen |
| 5 | [Berechtigungen und git](05-permissions-und-git.md) | nirgends gefragt werden — ausser bei git |
| 6 | [Benachrichtigung](06-benachrichtigung.md) | erfahren, wann Claude fertig ist, ohne hinzusehen |
| 7 | [MCP-Server](07-mcp.md) | Plugin-Server und eigenständige Server unterscheiden |
| 8 | [Der Wrapper](08-der-wrapper.md) | alles mit einem Kommando, plus Drift-Prüfung über alle Boxen |

Jedes Kapitel endet in einem Zustand, der läuft. Wer abbricht, hat etwas
Benutzbares.

## Die drei Sätze, um die es geht

1. **Jedes Projekt hat seine eigene Sandbox, alle aus demselben Image.** Die
   Sandbox-Grenze verläuft dort, wo die Projektgrenze verläuft.
2. **Ein neues Image erreicht bestehende Sandboxes nicht.** Das ist der Preis
   und der Grund, warum das Dockerfile hier voll ausgestattet ist.
3. **Es fragt nur bei git und bei wenigen unumkehrbaren Befehlen.** Alles andere
   läuft durch — bewusst.

## Was du brauchst

- macOS mit Docker Desktop und `sbx` (Docker Sandboxes)
- ein Claude-Abo (Max oder Pro) — der Abo-Weg ist hier der Standardpfad
- etwa 8 GB Plattenplatz für das Image
- Geduld beim ersten Bau: Chromium ist dabei

## Wenn du feststeckst

- [Cheatsheet](../cheatsheet.md) — alle Kommandos und die rohen `sbx`-Aufrufe
- [Fehlersuche](../troubleshooting.md) — nach Symptom sortiert
- [Architektur](../architektur.md) — die Begründungen hinter den Entscheidungen

Die Referenzfassung liegt neben dir im Repo: `v3/sbx-claude.sh`,
`v3/Dockerfile`, `v3/hooks/`. Das Tutorial baut genau das nach.
