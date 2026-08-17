# devbox

Dieses Repo baut Claude-Sandboxes auf Basis von Docker Sandboxes (`sbx`).
Es ist zugleich **Kursmaterial** — jede Datei wird von Lernenden gelesen.

Es gibt **drei Varianten**, die sich nichts teilen und nebeneinander laufen:

| | `devbox/` (Variante 1) | `solobox/` (Variante 2) | `v3/` (Variante 3) |
| --- | --- | --- | --- |
| Sandboxes | eine pro Profil | genau eine, systemweit | eine pro Projekt, ein Image |
| Aufruf | `./devbox/devbox.sh up privat` | `solobox up` im Projektordner | `sbx-claude up` im Projektordner |
| Conf | Pflicht | optional | optional |
| Globales aus `~/.claude` | über `SHARE_ALL` zuschaltbar | immer, inkl. Hooks und Plugins | immer; Hooks werden **ersetzt** |
| Berechtigungen | Image-Standard | `acceptEdits` | `bypassPermissions` + `ask` auf git |
| Benachrichtigung | unterdrückt | unterdrückt | funktioniert (Host-Wächter) |

Änderst du eine Variante, ist die andere **nicht** automatisch betroffen — aber
prüfe, ob die Begründung in `docs/architektur.md` bzw. `v3/docs/architektur.md`
noch stimmt.

⚠️ **Eine Ausnahme von dieser Regel gibt es doch, und sie ist bekannt:** `v3/`
benutzt `sbx skills import`, und das verlangt `feature.shareSkills` — eine
**maschinenweite** sbx-Einstellung. Ist sie an, hängt jede Sandbox auf dem
Rechner den geteilten, read-write Skill-Store ein, auch `solobox`, deren
`copy_skills` dann in den Store schreibt statt in einen Sandbox-Ordner. Steht in
`v3/docs/architektur.md`. Wer daran arbeitet, muss beide Varianten prüfen.

## Wichtig beim Arbeiten an diesem Repo

- **Kommentare auf Deutsch.** Sie sind Lehrmaterial, nicht Beiwerk. Erkläre das
  _Warum_, nicht das _Was_. Die `README.md` ist die einzige englische Datei.
- **Nur stabile `sbx`-Flags** in `devbox/devbox.sh`. `sbx kit` und `sbx skills`
  sind EXPERIMENTAL und gehören nicht in den kritischen Pfad — die Kit-Variante
  liegt bewusst separat unter `devbox/kit/`.
- **Netzregeln immer mit `--sandbox`**, nie global. Auf derselben Maschine kann
  ein anderes Sandbox-Setup laufen, das nicht verändert werden darf.
- **`SHARE_ALL` bleibt standardmäßig aus.** Der Schalter nimmt genau die
  Trennungen zurück, die Kapitel 6 begründet — das darf eine bewusste
  Profil-Entscheidung sein, nie eine Voreinstellung. Er nutzt bewusst `cp` +
  `sbx exec` statt des EXPERIMENTAL-Kommandos `sbx skills import`. `sbx mcp` ist
  dagegen nicht als experimentell markiert und darf verwendet werden.
- **Nichts `sbx/` nennen.** Fremde Wrapper erkennen diesen Ordnernamen im
  Git-Root automatisch und kapern sonst dieses Repo.
- Ändert sich das Verhalten, muss das passende Tutorial-Kapitel unter
  `docs/tutorial/` bzw. `docs/tutorial-solo/` mitgezogen werden.

## Zusätzlich für `solobox/`

- **Die eine Ausnahme von der Flag-Regel:** `--no-share-skills` ist in
  `sbx create --help` nicht dokumentiert und gehört zum EXPERIMENTAL-Kommando
  `sbx skills`. Es steht deshalb **nicht** im Standardweg, sondern hinter
  `ISOLATE_SKILLS=1`, und `supports_no_share_skills()` prüft vorher, ob die
  installierte `sbx`-Version es überhaupt kennt. Ohne diese Prüfung darf es
  nirgends verwendet werden.
- **Skills werden kopiert, nie verlinkt.** Grund steht bei `CLAUDE_LINKED`.
- **`settings.json` wird abgeleitet, nie gemountet.** Übernommen werden nur
  `enabledPlugins`, `extraKnownMarketplaces`, `model`, `effortLevel` und die
  Hooks abzüglich `HOOK_SKIP`. `permissions.defaultMode` wird auf `acceptEdits`
  **gesetzt** — nicht `bypassPermissions`, weil `~/dev` echt eingehängt ist.
- **`up` startet im aktuellen Verzeichnis** (`sbx exec -w`). Wer das ändert,
  bricht die projektlokale Konfiguration — Claude liest sie beim Start aus dem
  Arbeitsverzeichnis.
- **pnpm nie über `corepack`.** Die Aktivierung landet im Cache des Bau-Users,
  und `agent` lädt zur Laufzeit still eine andere Version nach. Nachgemessen,
  siehe Kommentar im Dockerfile.
- **Neue Einträge in `CLAUDE_SHARED` oder `ROOTS` sind Neuanlege-Ursachen.** Die
  Mount-Liste kommt ausschließlich aus `gewuenschte_mounts()` — `provision` legt
  danach an, `pruefe_stand` vergleicht dagegen. Wer eine zweite Liste einführt,
  bricht den Drift-Check.
- **Der Stempelblock bleibt am Ende des Dockerfiles.** Weiter oben entwertet ein
  neuer Stempelwert den Build-Cache aller darüberliegenden Schichten.
- **Die Shell-Prüfung bleibt die erste ausführbare Zeile.** `sh solobox.sh`
  ignoriert die Shebang, und `/bin/sh` ist auf macOS bash im POSIX-Modus ohne
  Prozess-Substitution. Erkennung zweistufig: leeres `BASH_VERSION` **oder**
  `shopt -qo posix` — unter `sh` ist `BASH_VERSION` nämlich gesetzt.
- **`SCRIPT_PATH` muss Symlinks auflösen.** `solobox` wird über einen Symlink in
  `~/.local/bin` aufgerufen; ohne `aufloesen()` sucht das Skript sein Dockerfile
  dort und scheitert mit `shasum: …/.local/bin/Dockerfile: No such file`.
- **`pruefe_stand` nie in eine Pipe oder `$(…)` stecken.** Subshell heißt: die
  gesetzte Stufe geht verloren, der Exitcode ist dann immer 0. Die Einrückung ist
  deshalb ein Parameter.
- **Safe Chain nie als Shell-Funktion.** Funktionen existieren nur in der Shell;
  `timeout npm install …`, `env npm …` und `xargs … npm` hebeln sie aus —
  nachgemessen, das Testpaket ging durch. Es müssen Shims im `PATH` sein, wie in
  `devbox/Dockerfile`. Schalter heißt hier `SOLOBOX_SAFE_CHAIN`.

## Zusätzlich für `v3/`

Die Fallen aus `solobox/` gelten hier alle mit (Shell-Prüfung, Symlink-Auflösung,
Stempelblock am Ende, `pruefe_stand` nie in einer Pipe, Safe Chain als Shims —
der Schalter heißt hier `SBX_CLAUDE_SAFE_CHAIN`). Dazu kommen sieben Regeln, die
nur hier gelten:

- **`sbx run` wird NIE benutzt, auch nicht beim ersten Start.** Es startet den
  Agenten mit `--dangerously-skip-permissions`. Bei einer Sandbox pro Projekt
  wäre das nicht die Ausnahme, sondern bei jedem neuen Projekt der Fall — der
  ganze Berechtigungsmodus wäre wirkungslos. Der Weg ist immer
  `sbx exec -it -w PFAD SANDBOX claude`; `/login` funktioniert darin.
- **Der Wächter übernimmt keinen Text aus dem Container.** Der Ereignisordner ist
  ein read-write Kanal aus der Sandbox auf den Host. Erlaubt sind genau ein Wort
  aus einer festen Liste und eine per Regex geprüfte Zahl; den Meldungstext
  formuliert `watch.sh` selbst, und `terminal-notifier` bekommt Argumente, nie
  eine Shell-Zeile. Wer hier Freitext durchlässt, baut AppleScript-Injection auf
  den Mac. Auch die Dateinamen werden geprüft, und die Leseposition liegt
  **ausserhalb** des Ereignisordners.
- **`notify.sh` gehört ins Image, nicht in einen Mount.** Ein Hook muss auch
  funktionieren, wenn vom Host nichts erreichbar ist. Was nicht ins Image kann —
  Ereignispfad, Sandbox-Name, Schwelle — bekommt er als **Argumente** aus der
  abgeleiteten `settings.json`. Es gab dafür einmal eine eigene Umgebungsdatei in
  der Sandbox; die war ein Umweg mit einem zusätzlichen Fehlerfall.
- **Es gibt keinen git-Hook mehr, und das ist eine Messung.** Nachgemessen mit
  `deny`-Regeln: Claude Code wendet Regeln auf **jedes Segment** einer Kette an
  und auch **in Command-Substitution**. `cd repo && git push` und `x=$(git push)`
  lösen die git-Regeln also von selbst aus. Der frühere `git-guard.sh` (133
  Zeilen Regex) deckte damit nur noch `bash -c "git push"` ab — dafür stehen
  jetzt `Bash(bash -c *)`, `Bash(sh -c *)` und `Bash(zsh -c *)` in `EXTRA_ASK`.
  Bewusst aufgegeben: Shell-Umleitungen nach `.git/` fragen nicht mehr.
- **Die ask-Muster heißen `Bash(git *VERB*)`, nicht `Bash(git VERB *)`.** Sonst
  rutscht `git -C unterordner commit` durch. Und `deny` auf `.git/**` ist Pflicht:
  `bypassPermissions` schaltet laut Doku ausgerechnet den Schutz der „protected
  paths" ab.
- **Der `sandbox`-Block der Host-`settings.json` wird nicht übernommen.** Seine
  Pfade zeigen im Container ins Leere und sähen dabei aus, als schützten sie
  etwas. `HOOK_UEBERNEHMEN` bleibt eine Liste, keine Heuristik — und die drei
  Ereignisse des Rückkanals (`UserPromptSubmit`, `Stop`, `Notification`) stehen
  nicht darin, weil v3 sie selbst besetzt.
- **`feature.shareSkills` wird nie still gesetzt.** Es wirkt maschinenweit (siehe
  Warnung oben). `up` fragt einmal, `doctor` benennt den Zustand,
  `ISOLATE_SKILLS=1` ist der Ausschalter pro Projekt.

Und weiterhin: **`gewuenschte_mounts()` ist die einzige Mount-Liste**, jetzt
zusätzlich mit dem Ereignisordner darin. Eine zweite Liste bricht den
Drift-Check.

## Aufbau

| Pfad                           | Inhalt                                          |
| ------------------------------ | ----------------------------------------------- |
| `devbox/Dockerfile`            | Toolchain des Images (Variante 1)               |
| `devbox/devbox.sh`             | Wrapper um `sbx` (der Hauptweg)                 |
| `devbox/devbox.conf.example`   | Profilvorlage                                   |
| `devbox/kit/kit.yaml`          | deklarative Variante (Kür)                      |
| `solobox/Dockerfile`           | Toolchain des Images (Variante 2)               |
| `solobox/solobox.sh`           | Wrapper für die eine Sandbox                    |
| `solobox/solobox.conf.example` | Konfigurationsvorlage (optional)                |
| `v3/Dockerfile`                | Toolchain des Images (Variante 3), voll ausgestattet |
| `v3/sbx-claude.sh`             | Wrapper: eine Sandbox pro Projekt               |
| `v3/sbx-claude.conf.example`   | Konfigurationsvorlage (optional)                |
| `v3/hooks/notify.sh`           | läuft IM Container: Ereigniszeile + Glocke      |
| `v3/hooks/watch.sh`            | läuft auf dem HOST: Ereignis → Meldung          |
| `docs/tutorial/`               | Tutorial Variante 1: Kapitel 0 plus sieben      |
| `docs/tutorial-solo/`          | Tutorial Variante 2: sieben Kapitel             |
| `v3/docs/tutorial/`            | Tutorial Variante 3: Kapitel 0 bis 8            |
| `docs/cheatsheet.md`           | alle Kommandos von Variante 1                   |
| `docs/cheatsheet-solo.md`      | alle Kommandos von Variante 2                   |
| `v3/docs/cheatsheet.md`        | alle Kommandos von Variante 3                   |
| `docs/architektur.md`          | die Begründungen (Varianten 1 und 2)            |
| `v3/docs/architektur.md`       | die Begründungen (Variante 3)                   |
| `docs/troubleshooting.md`      | Fehlersuche (Varianten 1 und 2)                 |
| `v3/docs/troubleshooting.md`   | Fehlersuche (Variante 3)                        |
| `scripts/check-links.sh`       | prüft relative Links in der Doku                |
| `.github/workflows/ci.yml`     | shellcheck + Linkprüfung                        |

## Vor dem Commit

Genau das, was die CI prüft:

```bash
shellcheck devbox/devbox.sh solobox/solobox.sh scripts/check-links.sh
shellcheck v3/sbx-claude.sh v3/hooks/notify.sh v3/hooks/watch.sh
bash -n devbox/devbox.conf.example
bash -n solobox/solobox.conf.example
bash -n v3/sbx-claude.conf.example
test -x devbox/devbox.sh && test -x solobox/solobox.sh
test -x v3/sbx-claude.sh && test -x v3/hooks/watch.sh
./scripts/check-links.sh
```

Der Container-Hook von v3 ist ohne Sandbox prüfbar. Das gehört mit zur Abnahme,
weil eine ungeprüfte Zusage eine Vermutung ist:

```bash
ORDNER="$(mktemp -d)"
printf '%s' '{"session_id":"t1"}' | sh v3/hooks/notify.sh start "$ORDNER" sbx-claude-t 60
echo $(( $(date +%s) - 142 )) > "${TMPDIR:-/tmp}/sbx-claude-start-t1"
printf '%s' '{"session_id":"t1"}' | sh v3/hooks/notify.sh stop  "$ORDNER" sbx-claude-t 60
cat "$ORDNER/sbx-claude-t.ereignisse"     # erwartet: "fertig<TAB>142"
```

Und der Wächter muss einen bösartigen Sandbox-Namen abweisen, statt ihn in eine
Meldung zu übernehmen — das ist die Vertrauensgrenze zum Mac:

```bash
printf '%s' '{"session_id":"t1"}' \
  | sh v3/hooks/notify.sh wartet "$ORDNER" 'x"; touch /tmp/BOESE; "' 60
ls "$ORDNER"     # erwartet: nur sbx-claude-t.ereignisse, keine zweite Datei
```

Kein `shellcheck` zur Hand:
`docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable /mnt/devbox/devbox.sh`

## Nach Änderungen am Dockerfile

```bash
./devbox/devbox.sh update
docker run --rm devbox/base:latest bash -lc 'python --version; pnpm --version'

# Variante 2
./solobox/solobox.sh update
docker run --rm solobox/base:latest bash -lc 'python --version; pnpm --version; gcc --version | head -1'

# Variante 3
./v3/sbx-claude.sh update
docker run --rm sbx-claude/base:latest bash -lc 'python --version; python3.10 --version; python3.14 --version; pnpm --version; gcc --version | head -1; gh --version; ruff --version; ls -l /usr/local/bin/sbx-claude-notify'
```

`pnpm --version` darf **keine** Corepack-Download-Meldung zeigen.

`update` statt `build --force`: Es sagt zusätzlich, welche bestehenden Sandboxes
das neue Template noch nicht haben — die erreicht ein Neubau nämlich nicht. In
Variante 3 ist das kein Randfall, sondern der Regelfall: dort gibt es eine
Sandbox pro Projekt, und jede einzelne braucht `rm` + `up` + `/login`.

## Fallen in `devbox.sh`

- **`set -euo pipefail` + `sbx`.** `sbx template ls` endet mit Exitcode 1, wenn
  man nicht bei Docker angemeldet ist. Jede Pipeline mit `sbx` in einer
  Zuweisung braucht deshalb ein `|| true`, sonst bricht das Skript stumm ab.
- **Keine Here-Docs für Schleifen.** Sie brauchen eine Temp-Datei, die in einer
  Sandbox nicht überall schreibbar ist. Prozess-Substitution
  (`done < <(...)`) statt Pipe — eine Pipe würde die Schleife in eine Subshell
  stecken und Zähler verlieren.
