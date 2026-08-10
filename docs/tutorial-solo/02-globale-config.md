# Kapitel 2 — Globale Konfiguration

**Ziel:** Deine Skills, Agents, Commands und Regeln liegen **einmal** auf dem
Host und gelten in der Sandbox überall — ohne Kopie in jedem Projekt.

**Am Ende dieses Kapitels:** Eine Sandbox, in der `/skills` und deine Agents
dasselbe zeigen wie auf dem Host.

---

## Was in `~/.claude` liegt — und was davon hinein darf

```bash
ls ~/.claude
```

Grob drei Gruppen:

| Gruppe | Beispiele | gehört in die Sandbox? |
|---|---|---|
| Deine Arbeit | `agents/`, `skills/`, `commands/`, `rules/`, `plugins/`, `hooks/` | **ja**, read-only |
| Deine Geheimnisse | `.credentials.json` | **nie** |
| Host-Zustand | `projects/`, `history.jsonl`, `sessions/`, `file-history/`, `ide/`, `.claude.json` | nein |
| Host-Einstellungen | `settings.json` | nicht mounten — ableiten (Kapitel 3) |

Die letzte Zeile ist die interessanteste: `settings.json` enthält Berechtigungen
und Pfade **deines Hosts**, teils einen kompletten `sandbox`-Block. Die gelten
für deinen Rechner, nicht für einen Container. Was davon sinnvoll ist, leiten wir
in Kapitel 3 ab.

## Einhängen

Die erste Gruppe kommt als zusätzliche, schreibgeschützte Workspaces dazu — beim
Anlegen, wie alles andere auch:

```bash
sbx rm --force solobox 2>/dev/null || true

sbx create -t solobox/base:latest --name solobox claude \
  ~/dev \
  ~/.claude/agents:ro \
  ~/.claude/skills:ro \
  ~/.claude/commands:ro \
  ~/.claude/rules:ro \
  ~/.claude/plugins:ro \
  ~/.claude/hooks:ro
```

> **Wenn `sbx` abbricht, weil ein Ordner fehlt:** das ist kein Fehler deiner
> Eingabe. `sbx` verweigert das Anlegen, wenn ein Mount-Ziel nicht existiert. Auf
> frisch eingerichteten Rechnern fehlen z.B. `commands/` oder `rules/`. Anlegen
> und noch einmal:
> ```bash
> mkdir -p ~/.claude/{agents,skills,commands,rules,plugins,hooks}
> ```
> Der Wrapper in Kapitel 6 macht genau das still im Hintergrund.

## Warum das allein nichts bringt

```bash
sbx exec -it solobox bash
```

In der Sandbox:

```bash
ls /Users/dein-name/.claude/skills   # da sind sie
ls ~/.claude/skills                  # und hier sucht Claude
```

Zusätzliche Workspaces landen unter ihrem **absoluten Host-Pfad**. In der Sandbox
ist dein Home aber `/home/agent`. Claude sucht seine Agents also unter
`/home/agent/.claude/agents` und findet dort nichts.

## Die Brücke: Symlinks

```bash
sbx exec solobox bash -c '
  mkdir -p "$HOME/.claude"
  for d in agents commands rules plugins hooks; do
    ln -sfn "/Users/dein-name/.claude/$d" "$HOME/.claude/$d"
  done
  ls -l "$HOME/.claude"
'
```

Erwartet: fünf Links, die auf den Host-Pfad zeigen.

## ⚠️ Der Sonderfall `skills` — die Falle dieses Kapitels

In der Liste oben fehlt `skills`. Absichtlich. Probiere aus, warum:

```bash
sbx exec solobox bash -c 'ls -la $HOME/.claude/skills; mount | grep -c skills || true'
```

`/home/agent/.claude/skills` ist **kein leeres Verzeichnis, das auf einen Link
wartet**. Dort hängt `sbx` seinen eigenen Skill-Store ein — und zwar denselben
für **alle** Sandboxes dieser Maschine.

Was passiert, wenn man trotzdem `ln -sfn` darauf loslässt? Kein Fehler. Der Link
landet **in** diesem Verzeichnis:

```
/home/agent/.claude/skills/skills -> /Users/dein-name/.claude/skills
```

Damit läge deine Konfiguration plötzlich auch in jeder anderen Sandbox dieses
Rechners — und zwar ohne eine einzige Warnung.

## Also: Skills kopieren, nicht verlinken

```bash
sbx exec solobox bash -c '
  quelle="/Users/dein-name/.claude/skills"
  ziel="$HOME/.claude/skills"
  mkdir -p "$ziel"
  ( cd "$quelle" && tar cf - . ) | ( cd "$ziel" && tar xf - --no-same-permissions )
  ls "$ziel"
'
```

Warum `tar` und nicht `cp -r`? Ist ein Skill-Ordner auf dem Host
schreibgeschützt (555 — bei installierten Plugin-Skills kommt das vor), legt
`cp` das **Zielverzeichnis** mit denselben Rechten an und kann anschließend
nichts mehr hineinschreiben. Der Skill fehlt dann, und die Meldung dazu
(`setting permissions ... Permission denied`) sieht nach einer Lappalie aus.
`tar` setzt die Rechte der Zielverzeichnisse erst zum Schluss und schreibt
deshalb sauber hinein — auch beim zweiten und dritten Mal.

Weil es eine **Kopie** ist und kein Mount, gilt: neue Skills auf dem Host sind
erst nach dem nächsten Durchlauf in der Sandbox. Der Wrapper hat dafür
`solobox sync`.

## Wer teilt sich diesen Store mit dir?

Das ist keine Randnotiz, sondern die Kehrseite der Bequemlichkeit:

```bash
sbx ls
```

Jede Sandbox in dieser Liste sieht die Skills, die du gerade hineinkopiert hast.
Auf einem Rechner, auf dem nur deine eigenen Sandboxes laufen, ist das genau, was
du willst: Skill einmal ablegen, überall verfügbar. Auf einem geteilten Rechner
ist es ein Seitenkanal.

**Der Ausweg**, wenn du ihn brauchst: `sbx create` kennt ein
`--no-share-skills`. Damit ist `/home/agent/.claude/skills` ein ganz normales
Verzeichnis, das nur dieser Sandbox gehört — die Kopie oben funktioniert
unverändert, sie landet nur nicht mehr im geteilten Store.

```bash
sbx create --no-share-skills -t solobox/base:latest --name solobox claude ~/dev ...
```

⚠️ Dieses Flag steht **nicht** in `sbx create --help`; es gehört zum als
EXPERIMENTAL markierten `sbx skills` und kann in einer künftigen Version
verschwinden. Deshalb ist es im Wrapper nicht der Standardweg, sondern ein
Schalter (`ISOLATE_SKILLS=1`), der vorher prüft, ob deine `sbx`-Version das Flag
überhaupt kennt.

## Prüfen

Starte Claude und sieh nach:

```bash
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude
```

```
/skills
/agents
```

Erwartet: dieselben Einträge wie auf deinem Host.

Fehlt etwas, geht die Suche in dieser Reihenfolge:
1. Ist der Ordner überhaupt gemountet? → `sbx ls` zeigt die Workspaces.
2. Zeigt der Symlink richtig? → `sbx exec solobox ls -l '$HOME/.claude'`
3. Bei Skills: liegt die Kopie im Store? → `sbx exec solobox ls '$HOME/.claude/skills'`

---

➡️ **Weiter mit [Kapitel 3 — Hooks, Plugins, Settings](03-hooks-plugins-settings.md)**
