# devbox

Dieses Repo baut Claude-Sandboxes auf Basis von Docker Sandboxes (`sbx`).
Es ist zugleich **Kursmaterial** — jede Datei wird von Lernenden gelesen.

Es gibt **zwei Varianten**, die sich nichts teilen und nebeneinander laufen:

| | `devbox/` (Variante 1) | `solobox/` (Variante 2) |
| --- | --- | --- |
| Sandboxes | eine pro Profil | genau eine, systemweit |
| Aufruf | `./devbox/devbox.sh up privat` | `solobox up` im Projektordner |
| Conf | Pflicht | optional |
| Globales aus `~/.claude` | über `SHARE_ALL` zuschaltbar | immer, inkl. Hooks und Plugins |

Änderst du eine Variante, ist die andere **nicht** automatisch betroffen — aber
prüfe, ob die Begründung in `docs/architektur.md` für beide noch stimmt.

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
- **`pruefe_stand` nie in eine Pipe oder `$(…)` stecken.** Subshell heißt: die
  gesetzte Stufe geht verloren, der Exitcode ist dann immer 0. Die Einrückung ist
  deshalb ein Parameter.
- **Safe Chain nie als Shell-Funktion.** Funktionen existieren nur in der Shell;
  `timeout npm install …`, `env npm …` und `xargs … npm` hebeln sie aus —
  nachgemessen, das Testpaket ging durch. Es müssen Shims im `PATH` sein, wie in
  `devbox/Dockerfile`. Schalter heißt hier `SOLOBOX_SAFE_CHAIN`.

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
| `docs/tutorial/`               | Tutorial Variante 1: Kapitel 0 plus sieben      |
| `docs/tutorial-solo/`          | Tutorial Variante 2: sieben Kapitel             |
| `docs/cheatsheet.md`           | alle Kommandos von Variante 1                   |
| `docs/cheatsheet-solo.md`      | alle Kommandos von Variante 2                   |
| `docs/architektur.md`          | die Begründungen (beide Varianten)              |
| `docs/troubleshooting.md`      | Fehlersuche (beide Varianten)                   |
| `scripts/check-links.sh`       | prüft relative Links in der Doku                |
| `.github/workflows/ci.yml`     | shellcheck + Linkprüfung                        |

## Vor dem Commit

Genau das, was die CI prüft:

```bash
shellcheck devbox/devbox.sh solobox/solobox.sh scripts/check-links.sh
bash -n devbox/devbox.conf.example
bash -n solobox/solobox.conf.example
test -x devbox/devbox.sh && test -x solobox/solobox.sh
./scripts/check-links.sh
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
```

`pnpm --version` darf **keine** Corepack-Download-Meldung zeigen.

`update` statt `build --force`: Es sagt zusätzlich, welche bestehenden Sandboxes
das neue Template noch nicht haben — die erreicht ein Neubau nämlich nicht.

## Fallen in `devbox.sh`

- **`set -euo pipefail` + `sbx`.** `sbx template ls` endet mit Exitcode 1, wenn
  man nicht bei Docker angemeldet ist. Jede Pipeline mit `sbx` in einer
  Zuweisung braucht deshalb ein `|| true`, sonst bricht das Skript stumm ab.
- **Keine Here-Docs für Schleifen.** Sie brauchen eine Temp-Datei, die in einer
  Sandbox nicht überall schreibbar ist. Prozess-Substitution
  (`done < <(...)`) statt Pipe — eine Pipe würde die Schleife in eine Subshell
  stecken und Zähler verlieren.
