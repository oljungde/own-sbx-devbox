# devbox

Dieses Repo baut eine Claude-Sandbox auf Basis von Docker Sandboxes (`sbx`).
Es ist zugleich **Kursmaterial** — jede Datei wird von Lernenden gelesen.

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
  `docs/tutorial/` mitgezogen werden.

## Aufbau

| Pfad                         | Inhalt                                          |
| ---------------------------- | ----------------------------------------------- |
| `devbox/Dockerfile`          | Toolchain des Images                            |
| `devbox/devbox.sh`           | Wrapper um `sbx` (der Hauptweg)                 |
| `devbox/devbox.conf.example` | Profilvorlage                                   |
| `devbox/kit/kit.yaml`        | deklarative Variante (Kür)                      |
| `docs/tutorial/`             | Tutorial: Kapitel 0 (Setup) plus sieben Kapitel |
| `docs/cheatsheet.md`         | alle Kommandos auf einer Seite                  |
| `docs/architektur.md`        | die Begründungen                                |
| `docs/troubleshooting.md`    | Fehlersuche                                     |
| `scripts/check-links.sh`     | prüft relative Links in der Doku                |
| `.github/workflows/ci.yml`   | shellcheck + Linkprüfung                        |

## Vor dem Commit

Genau das, was die CI prüft:

```bash
shellcheck devbox/devbox.sh scripts/check-links.sh
bash -n devbox/devbox.conf.example
./scripts/check-links.sh
```

Kein `shellcheck` zur Hand:
`docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable /mnt/devbox/devbox.sh`

## Nach Änderungen am Dockerfile

```bash
./devbox/devbox.sh update
docker run --rm devbox/base:latest bash -lc 'python --version; pnpm --version'
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
