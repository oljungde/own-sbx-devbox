# Kapitel 6 — Der Wrapper

**Ziel:** Alles aus den Kapiteln 1 bis 5 auf ein Kommando reduzieren — ohne dass
dabei Magie entsteht.

**Am Ende dieses Kapitels:** `solobox up` in jedem Projektordner, und du weißt,
welche Zeile welchen Handgriff ersetzt.

---

## Was der Wrapper ersetzt

| Kapitel | Handgriff                                          | im Wrapper           |
| ------- | -------------------------------------------------- | -------------------- |
| 0       | `docker build`, `docker save`, `sbx template load` | `cmd_build`          |
| 1       | `sbx create` mit allen Wurzeln                     | `provision`          |
| 1       | `sbx exec -it -w "$PWD" … claude`                  | `cmd_up`             |
| 2       | Symlinks für agents/commands/rules/plugins/hooks   | `link_shared_config` |
| 2       | `tar`-Kopie der Skills                             | `copy_skills`        |
| 3       | abgeleitete `settings.json`                        | `apply_settings`     |
| 4       | `sbx mcp load` je Server                           | `load_mcp`           |
| 1–4     | Netzregeln setzen                                  | `apply_network`      |

Mehr nicht. Jede Zeile darin kannst du auch von Hand tippen — genau das hast du
in den letzten fünf Kapiteln getan.

## Einrichten

```bash
chmod +x solobox/solobox.sh
./solobox/solobox.sh install
```

`install` legt einen Symlink `~/.local/bin/solobox` an, der ins Repo zeigt. Das
ist nötig, weil solobox **im Projektordner** aufgerufen wird — ein relativer Pfad
ins Repo wäre dort unbrauchbar.

Liegt `~/.local/bin` nicht auf deinem `PATH`, sagt `install` es dir. Für bash
oder zsh:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

> Der Symlink zeigt ins Repo. Verschiebst du das Repo, zeigt er ins Leere —
> `solobox doctor` meldet das.

## Der erste Lauf

```bash
solobox doctor
```

Erwartet: Werkzeuge vorhanden, Symlink gefunden, Template auf Stand, und der
Hinweis, dass keine Konfiguration existiert — mit den geltenden Standardwerten.

Genau das ist der Unterschied zu devbox: **solobox läuft ohne
Konfigurationsdatei.** Sie ist nur da, um Standardwerte zu übersteuern.

```bash
cd ~/dev/own/mein-projekt
solobox up
```

Beim allerersten Mal legt der Wrapper die Sandbox an und startet über `sbx run` —
dort meldest du dich einmal bei Claude an. Ab dem zweiten Mal startet er Claude
direkt in dem Ordner, in dem du stehst.

## Die Kommandos

```bash
solobox up [pfad]   # Sandbox anlegen (einmalig) und Claude starten
solobox sync        # Skills, Settings, MCP in die LAUFENDE Sandbox nachziehen
solobox status      # Template, Sandbox, Wurzeln, MCP, Nachbarn
solobox allow HOST  # einen Host freigeben
solobox shell       # bash in der Sandbox
solobox update      # Template neu bauen
solobox doctor      # Host prüfen
solobox rm          # Sandbox entfernen (fragt nach)
```

Zwei davon lohnen einen zweiten Blick.

### `sync` — das Kommando, das es bei devbox nicht gibt

Skills werden **kopiert**, nicht gemountet (Kapitel 2). Legst du auf dem Host
einen neuen Skill an oder installierst ein Plugin, ist das in der laufenden
Sandbox noch nicht sichtbar:

```bash
solobox sync
```

Das führt genau die Schritte aus, die `up` vor dem Start macht — ohne Start. Die
laufende Claude-Sitzung sieht neue Skills nach einem Neustart der Sitzung.

### `check` — muss ich neu bauen?

Die Frage „muss ich etwas neu bauen?" hat **vier** Ursachen, und sie kosten sehr
unterschiedlich viel. Genau das ist der Punkt dieses Kommandos: nicht irgendetwas
melden, sondern die **billigste ausreichende Maßnahme** nennen.

```bash
solobox check
```

| Ebene | Frage | Woran es erkannt wird | Maßnahme |
| --- | --- | --- | --- |
| 1 | Ist das lokale Image auf dem Stand des Dockerfiles? | Label `solobox.dockerfile-sha` gegen `shasum` der Datei | `solobox build` |
| 2 | Liegt dieses Image auch im sbx-Store? | Image-ID gegen `sbx template ls` | `solobox build` |
| 3 | Läuft die Sandbox auf diesem Image? | `/etc/solobox-stamp` in der Sandbox | `solobox rm && solobox up` |
| 4 | Passen die Mounts zur Konfiguration? | `sbx ls --json` gegen `ROOTS` + `CLAUDE_SHARED` | `solobox rm && solobox up` |

Ebene 4 ist die, die man ohne Werkzeug übersieht: Ergänzt du `ROOTS` um einen
Ordner, ändert sich **nichts** — die Sandbox hat ihre Workspaces beim Anlegen
bekommen und kennt den neuen Pfad nie. `check` vergleicht deshalb, was
eingehängt *ist*, mit dem, was eingehängt *würde*:

```
--- 4. Mounts gegen Konfiguration ---
  ✗ Sandbox passt nicht zur Konfiguration — 'solobox rm && solobox up'
      fehlt in der Sandbox:  /Users/du/dev/work
      Grund: Workspaces sind nur beim Anlegen setzbar.
```

Der Exitcode ist die höchste nötige Stufe — damit taugt `check` auch für ein
Skript oder eine CI:

| Code | Bedeutung |
| --- | --- |
| 0 | alles aktuell |
| 1 | `solobox sync` genügt |
| 2 | `solobox build` nötig |
| 3 | `solobox rm && solobox up` nötig |

```bash
solobox check || echo "Handlungsbedarf, Stufe $?"
solobox check --base     # fragt zusätzlich die Registry (Netz, ein paar Sekunden)
```

`up` ruft denselben Check vor dem Start auf und **fragt** bei Stufe 3, ob es die
Sandbox jetzt neu anlegen soll — mit der Ansage, was das kostet. Es löscht nie
ungefragt.

### Warum ein Stempel im Image und keine Merkdatei

Frühere Fassungen merkten sich den Dockerfile-Hash in
`~/.local/state/solobox/`. Das geht schief, sobald diese Datei fehlt — nach
einem Aufräumen, auf einem zweiten Rechner, oder wenn das Image von Hand mit
`docker save` + `sbx template load` geladen wurde. Dann meldete `status`
„Herkunft unbekannt", und der Check war wertlos.

Deshalb trägt jedes Image seine Herkunft jetzt **selbst** mit sich:

```bash
docker image inspect solobox/base:latest \
  --format '{{index .Config.Labels "solobox.dockerfile-sha"}}'
sbx exec solobox cat /etc/solobox-stamp
shasum -a 256 solobox/Dockerfile | cut -d' ' -f1     # muss übereinstimmen
```

> 🎯 **Beobachtete Tatsachen schlagen Merkzettel.** Ein Merkzettel kann fehlen
> oder lügen; ein Label im Image und eine Datei in der Sandbox können es nicht.

Die Merkdatei gibt es weiterhin — aber nur noch als Rückfall für Images, die
noch keinen Stempel tragen.

### `status` — und die Zeile, die man nicht überliest

```bash
solobox status
```

Unter „Andere Sandboxes auf dieser Maschine" stehen die Sandboxes, die sich den
Skill-Store mit dir teilen. Solange `ISOLATE_SKILLS=0` ist, sehen sie deine
globalen Skills. Das ist die Kehrseite der Bequemlichkeit aus Kapitel 2, und
deshalb steht sie in der Statusausgabe und nicht im Kleingedruckten.

Ebenfalls dort: die **eingehängten Wurzeln**. Die wurden beim Anlegen festgelegt
und lassen sich nicht ändern — nach ein paar Wochen weiß niemand mehr auswendig,
was die Sandbox eigentlich sieht.

## Die Konfiguration — wenn du sie brauchst

```bash
mkdir -p ~/.config/solobox
cp solobox/solobox.conf.example ~/.config/solobox/solobox.conf
```

Fünf Variablen, alle optional:

| Variable          | Wofür                                         | Standard            |
| ----------------- | --------------------------------------------- | ------------------- |
| `ROOTS`           | was die Sandbox sieht (**nur Verzeichnisse**) | `~/dev`             |
| `EXTRA_HOSTS`     | zusätzliche Netzziele                         | leer                |
| `MCP_SERVERS`     | per `sbx mcp add` registrierte Server         | leer                |
| `HOOK_SKIP`       | Hooks, die im Container nicht gelten          | `Notification Stop` |
| `PERMISSION_MODE` | wie viel Claude ohne Rückfrage darf           | `acceptEdits`       |
| `ISOLATE_SKILLS`  | eigener statt geteilter Skill-Store           | `0`                 |

⚠️ `ROOTS` wirkt nur beim **Anlegen**. Eine Änderung daran verlangt
`solobox rm && solobox up` — und das kostet den Login.

## Die Fallen im Skript

Drei Stellen, die anders aussehen als nötig, und jede hat einen Grund. Sie stehen
so auch in `devbox.sh`, weil sie an `sbx` selbst hängen:

**1. `|| true` hinter jedem `sbx` in einer Zuweisung.**
`sbx template ls` endet mit Exitcode 1, solange man nicht bei Docker angemeldet
ist. Mit `set -euo pipefail` würde dieser Status in die Zuweisung wandern und das
Skript **stumm** beenden.

**2. Prozess-Substitution statt Pipe bei Schleifen.**
Eine Pipe steckt die Schleife in eine Subshell — Zähler darin sind danach wieder
null.

**3. `printf` statt Here-Doc in `usage()`.**
Ein Here-Doc legt die Zeilen erst in eine temporäre Datei. Rufst du solobox
einmal aus einer eingeschränkten Umgebung auf, ist das Temp-Verzeichnis nicht
schreibbar — und dann scheitert schon die Hilfe.

Dazu eine, die es nur hier gibt:

**4. `supports_no_share_skills()` fragt `sbx` ohne Pfad.**
Unbekannte Flags meldet `sbx` mit `unknown flag`, fehlende Pfade mit
`requires at least`. Kommt die Pfad-Meldung, ist das Flag bekannt. So lässt sich
ein undokumentiertes Flag prüfen, ohne etwas anzulegen.

## Prüfen, dass alles zusammenpasst

```bash
solobox doctor
solobox status

cd ~/dev/own/mein-projekt
solobox up
```

In der Sitzung:

```bash
/skills     # global + projektlokal
/agents     # global
/plugin     # deine Plugins
/mcp        # Plugin-Server + geladene Server
/status     # Arbeitsverzeichnis = dein Projekt
```

Sitzt alles, bist du durch.

---

## Und jetzt?

- [cheatsheet-solo.md](../cheatsheet-solo.md) — alles auf einer Seite
- [architektur.md](../architektur.md) — warum es so gebaut ist, inklusive der
  Unterschiede zu Variante 1
- [troubleshooting.md](../troubleshooting.md) — wenn etwas klemmt

Und wenn dir die eine Sandbox doch zu eng wird: Variante 1 liegt daneben und
läuft parallel. Beide teilen sich weder Template noch Zustand — nur den
Skill-Store, und den nur, solange `ISOLATE_SKILLS=0` ist.
