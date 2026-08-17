# Kapitel 4 — Globale Konfiguration

In `~/.claude` steckt deine Arbeit: Agents, Commands, Rules, Plugins,
Output-Styles, Workflows und Skills. Die soll in jeder Projekt-Sandbox
verfügbar sein.

## Was hinein darf und was nicht

| Ordner | Weg | Grund |
| --- | --- | --- |
| `agents/` | `:ro` einhängen + verlinken | reine Textdateien |
| `commands/` | `:ro` einhängen + verlinken | dito |
| `rules/` | `:ro` einhängen + verlinken | dito |
| `output-styles/` | `:ro` einhängen + verlinken | dito |
| `workflows/` | `:ro` einhängen + verlinken | dito |
| `plugins/` | `:ro` einhängen + verlinken | 86 MB, aber nötig für MCP und Skills der Plugins |
| `skills/` | **`sbx skills import`** | sbx hat dafür ein eigenes Kommando, siehe unten |
| `hooks/` | **gar nicht** | die Hooks kommen aus dem Image, siehe Kapitel 6 |
| `settings.json` | **abgeleitet**, nie gemountet | siehe Kapitel 5 |
| `.claude.json` | **nie** | dort stehen MCP-Einträge und Sitzungszustand gemischt |

## Einhängen

```bash
sbx create --name sbx-claude-api claude \
  ~/dev/own/api \
  ~/.claude/agents:ro \
  ~/.claude/commands:ro \
  ~/.claude/rules:ro \
  ~/.claude/plugins:ro \
  ~/.claude/output-styles:ro \
  ~/.claude/workflows:ro \
  ~/.local/state/sbx-claude/events
```

Drei Dinge dazu:

1. **Mounts gibt es nur beim `create`.** An einer bestehenden Sandbox lehnt sbx
   sie ab. Was hier fehlt, kostet später eine Neuanlage samt `/login`.
2. **Nur Verzeichnisse.** Eine einzelne Datei wird abgewiesen:
   `ERROR: workspace path exists but is not a directory: /Users/du/.gitconfig`.
   Deshalb wird die Git-Identität in Kapitel 8 als zwei Werte übertragen und
   nicht als Datei.
3. Der letzte Eintrag ohne `:ro` ist der Rückkanal für Kapitel 6.

> ⚠️ In `zsh` muss die Variable geklammert werden: `"$HOME/.claude/$d:ro"` liest
> `zsh` als History-Modifier `:r` und macht daraus `…/agentso`. Richtig ist
> `"$HOME/.claude/${d}:ro"`.

## Der Haken: der Pfad stimmt nicht

sbx hängt am **gleichen absoluten Pfad** ein wie auf dem Host. In der Sandbox
liegt dein Kram also unter `/Users/du/.claude/agents` — aber `$HOME` ist dort
`/home/agent`. Claude sucht in `/home/agent/.claude/agents` und findet nichts.
Ohne Fehlermeldung.

Die Brücke sind Symlinks:

```bash
sbx exec sbx-claude-api bash -c '
  for d in agents commands rules plugins output-styles workflows; do
    ln -sfn "/Users/du/.claude/$d" "$HOME/.claude/$d"
  done
'
```

Prüfen:

```bash
sbx exec sbx-claude-api ls -la /home/agent/.claude/
```

## ⚠️ Skills: der native Weg und sein Preis

Für Skills hat sbx ein eigenes Kommando:

```bash
sbx skills import --dry-run     # erst ansehen
sbx skills import
```

Es liest `~/.agents/skills`, `~/.claude/skills`, `~/.copilot/skills`,
`~/.cursor/skills` und `~/.factory/skills` in einen persistenten Store, den
Sandboxes einhängen. Das ist bequem — und es hat zwei Haken, die man kennen muss:

**Erstens** hängt es an einem Feature-Flag, und das ist eine **maschinenweite**
sbx-Einstellung:

```bash
sbx settings get feature.shareSkills --json
sbx settings set feature.shareSkills true
```

Ist es aus, schreibt `sbx skills import` in einen Store, den niemand einhängt —
also wirkungslos. Ist es an, hängt **jede** Sandbox auf diesem Rechner den Store
ein, auch fremde. `sbx-claude` schaltet das Flag deshalb niemals still um; es
fragt einmal.

**Zweitens** ist der Store **read-write und von allen geteilt**. Bei einer Box
pro Projekt heisst das: der Agent in Projekt A kann einen Skill verändern, den
Projekt B morgen ausführt. Das ist genau die Grenze, die eine Box pro Projekt
ziehen soll — und sie ist hier offen.

Wer das für ein bestimmtes Projekt nicht will:

```bash
ISOLATE_SKILLS=1        # in ~/.config/sbx-claude/sbx-claude.conf
```

Dann bekommt die Box beim Anlegen `--no-share-skills`. Auch dazu eine Warnung:
Diese Flag steht **nicht** in `sbx create --help` und gehört zum
EXPERIMENTAL-Kommando `sbx skills`. Der Wrapper prüft vorher, ob die installierte
sbx-Version sie überhaupt kennt — ohne diese Probe darf sie nirgends benutzt
werden.

Wer sich den Store mit dir teilt:

```bash
sbx ls --json | grep -i skill
```

## ⚠️ Plugins sind read-only

`:ro` heisst: `/plugin install` **in** der Sandbox scheitert. Das ist Absicht —
installiert wird auf dem Host:

```bash
# auf dem Host
claude          # /plugin install …
# dann
sbx-claude sync
```

## Projektlokale Ergänzungen

`CLAUDE.md`, `.claude/` und `.mcp.json` **im Projekt** funktionieren ohne alles
Weitere, weil das Projekt eingehängt ist. Voraussetzung ist nur, dass Claude im
Projekt startet — das leistet `sbx exec -w` aus Kapitel 1.

Gegenprobe:

```bash
echo '# Antworte immer mit "PROBE OK" am Anfang.' > ~/dev/own/probe-api/CLAUDE.md
sbx-claude up
```

Wenn die Antwort nicht mit `PROBE OK` beginnt, startet Claude im falschen
Verzeichnis.

Weiter mit [Kapitel 5](05-permissions-und-git.md).
