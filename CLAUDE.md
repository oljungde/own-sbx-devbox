# devbox

Dieses Repo baut eine Claude-Sandbox auf Basis von Docker Sandboxes (`sbx`).
Es ist zugleich **Kursmaterial** — jede Datei wird von Lernenden gelesen.

## Wichtig beim Arbeiten an diesem Repo

- **Kommentare auf Deutsch.** Sie sind Lehrmaterial, nicht Beiwerk. Erkläre das
  *Warum*, nicht das *Was*. Die `README.md` ist die einzige englische Datei.
- **Nur stabile `sbx`-Flags** in `devbox/devbox.sh`. `sbx kit` und `sbx skills`
  sind EXPERIMENTAL und gehören nicht in den kritischen Pfad — die Kit-Variante
  liegt bewusst separat unter `devbox/kit/`.
- **Netzregeln immer mit `--sandbox`**, nie global. Auf derselben Maschine kann
  ein anderes Sandbox-Setup laufen, das nicht verändert werden darf.
- **Nichts `sbx/` nennen.** Fremde Wrapper erkennen diesen Ordnernamen im
  Git-Root automatisch und kapern sonst dieses Repo.
- Ändert sich das Verhalten, muss das passende Tutorial-Kapitel unter
  `docs/tutorial/` mitgezogen werden.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `devbox/Dockerfile` | Toolchain des Images |
| `devbox/devbox.sh` | Wrapper um `sbx` (der Hauptweg) |
| `devbox/devbox.conf.example` | Profilvorlage |
| `devbox/kit/kit.yaml` | deklarative Variante (Kür) |
| `docs/tutorial/` | siebenteiliges Tutorial |
| `docs/architektur.md` | die Begründungen |
| `docs/troubleshooting.md` | Fehlersuche |

## Nach Änderungen am Dockerfile

```bash
./devbox/devbox.sh build --force
docker run --rm devbox/base:latest bash -lc 'python --version; pnpm --version'
```

`pnpm --version` darf **keine** Corepack-Download-Meldung zeigen.
