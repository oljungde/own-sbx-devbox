# Kapitel 6 — Globale und lokale Konfiguration

**Ziel:** Deine Skills, Agents und Commands sollen in der Sandbox verfügbar
sein — ohne sie in jedes Projekt zu kopieren.

**Am Ende dieses Kapitels:** Eine Sandbox, die deine globale Claude-Konfiguration
kennt und zusätzlich projektlokale Einstellungen berücksichtigt.

---

## Die Ausgangslage

Aus Kapitel 1 kennst du den Satz schon:

> Sandboxes do not inherit user-level configuration from the host machine, such
> as `~/.claude`. Only project-level configuration files located within the
> working directory are accessible inside the sandbox.

Das ist gut so — in `~/.claude` liegt auch deine `.credentials.json`. Aber es
heißt eben auch: deine sorgfältig gebauten Skills und Agents sind weg.

Der naheliegende Ausweg wäre, sie in jedes Projekt zu kopieren. Bei zwanzig
Projekten hast du dann zwanzig Kopien, die auseinanderlaufen. Das wollen wir
nicht.

## Der Weg: gezielt mounten

Wir hängen genau die Unterordner ein, die wir brauchen — read-only:

```bash
sbx create -t devbox/base:latest --name devbox-privat claude \
  ~/dev/own \
  ~/.claude/agents:ro \
  ~/.claude/skills:ro \
  ~/.claude/commands:ro \
  ~/.claude/rules:ro \
  ~/.claude/plugins:ro
```

Drei bewusste Entscheidungen dahinter:

**Gezielte Unterordner statt `~/.claude` komplett.** Sonst läge deine
`.credentials.json` im Container.

**`:ro` ist Pflicht.** Ohne Schreibschutz könnte ein Agent im Container deine
globalen Skills verändern — und die gelten dann auf dem Host für *alle* deine
Projekte. Das wäre ein Weg aus der Sandbox heraus.

**`settings.json` bleibt draußen.** Da stehen Berechtigungen für deinen Host
drin, die im Container nicht passen.

## Der Haken: der Pfad stimmt nicht

Extra-Workspaces landen unter ihrem **absoluten Host-Pfad**. Deine Skills liegen
in der Sandbox also unter `/Users/du/.claude/skills`.

Claude sucht sie aber unter `/home/agent/.claude/skills`.

Die Brücke ist ein Symlink:

```bash
sbx exec -d devbox-privat bash -c '
  mkdir -p "$HOME/.claude"
  for d in agents skills commands rules plugins; do
    ln -sfn "/Users/du/.claude/$d" "$HOME/.claude/$d"
  done
'
```

Der Wrapper in Kapitel 7 macht das automatisch und setzt den Host-Pfad richtig
ein.

Prüfen:

```bash
sbx exec -it devbox-privat bash -c 'ls -la ~/.claude'
```

Du solltest Symlinks sehen, die auf die gemounteten Pfade zeigen.

## Wenn ein Ordner noch nicht existiert

`sbx create` bricht ab, wenn ein zu mountender Ordner nicht existiert. Gerade
`~/.claude/rules` fehlt auf frisch eingerichteten Rechnern oft. Deshalb legt der
Wrapper fehlende Ordner vorher an:

```bash
for d in agents skills commands rules plugins; do
  mkdir -p "$HOME/.claude/$d"
done
```

Klein, aber es entscheidet darüber, ob das Setup bei der Hälfte der Gruppe
abbricht.

## Der native Weg — und warum wir ihn nicht nehmen

`sbx` bringt selbst etwas mit:

```bash
sbx skills import      # kopiert u.a. aus ~/.claude/skills
```

Klingt einfacher. Drei Gründe, warum wir trotzdem mounten:

| | `sbx skills import` | Unser `:ro`-Mount |
|---|---|---|
| Aktualität | **Kopie** — nach jeder Änderung neu importieren | live |
| Schreibrechte | Store wird **read-write** gemountet | read-only |
| Umfang | nur `skills` | skills, agents, commands, rules, plugins |
| Stabilität | als **EXPERIMENTAL** markiert | stabile Flags |

Besonders die zweite Zeile: Ein read-write gemounteter, von allen Sandboxes
geteilter Store bedeutet, dass eine Sandbox die Skills aller anderen verändern
kann.

Probier es ruhig aus — aber wisse, was du tust.

## Projektlokale Konfiguration

Das Schöne: Projektlokales funktioniert **von selbst**, weil es im gemounteten
Projektordner liegt.

```
mein-projekt/
├── .claude/
│   ├── settings.json      # Hooks, Berechtigungen für DIESES Projekt
│   ├── skills/            # projektspezifische Skills
│   └── agents/            # projektspezifische Agents
├── .mcp.json              # MCP-Server für DIESES Projekt
└── CLAUDE.md              # Projektanweisungen
```

Diese Dateien gehören **ins Repo**. Das ist der eigentliche Vorteil: Sie sind
versioniert, im Team geteilt, und jeder bekommt dieselbe Umgebung.

**Faustregel:**

| | Wo |
|---|---|
| Brauche ich in jedem Projekt | global, `~/.claude/`, gemountet |
| Gehört zu diesem einen Projekt | lokal, `.claude/` im Repo |

**Hooks** laufen übrigens **im Container**. Ein Hook, der ein Werkzeug aufruft,
das nur auf deinem Mac existiert, schlägt in der Sandbox fehl. Halte
projektlokale Hooks portabel.

## MCP-Server

Zwei Wege, mit klarer Arbeitsteilung:

**① Projektlokale `.mcp.json`** — der Standardweg. Liegt im Repo, wird
automatisch gefunden, ist versionierbar:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

Wichtig: Der Host, den der Server anspricht, muss in der Netzwerk-Policy stehen
(Kapitel 4) — sonst startet er, kommt aber nicht raus.

**② `sbx mcp` für Dienste mit OAuth-Login** — Atlassian, Linear, Notion und
Ähnliches. Deren Anmeldeflow im Container abzuwickeln ist mühsam. `sbx` betreibt
diese Server **außerhalb** der Sandbox und regelt die Anmeldung dort:

```bash
sbx mcp add linear --url https://mcp.linear.app/mcp
sbx mcp auth linear
sbx mcp load linear --sandbox devbox-privat
```

Registrierte Server ansehen: `sbx mcp ls`.

---

## Abnahme dieses Kapitels

```bash
sbx exec -it devbox-privat bash -c 'ls -la ~/.claude'   # Symlinks vorhanden
```

Und in einer Claude-Session in der Sandbox: Tauchen deine globalen Skills und
Agents auf? Wenn ja, ist das Kapitel geschafft.

> 📌 **Bekannte Einschränkung bei `plugins`:** Claude Code merkt sich in einer
> separaten Datei, welche Plugins aktiviert sind — und die mounten wir bewusst
> nicht mit. Es kann daher sein, dass die Plugin-Ordner zwar in der Sandbox
> liegen, aber nicht geladen werden. **Fallback:** Kopiere die zwei, drei
> Plugin-Skills, die du wirklich überall brauchst, nach `~/.claude/skills` —
> die werden zuverlässig gefunden.

---

➡️ **Weiter mit [Kapitel 7 — Das Wrapper-Skript](07-wrapper-und-kit.md)**
