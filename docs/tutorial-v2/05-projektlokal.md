# Kapitel 5 — Projektlokale Ergänzungen

**Ziel:** Nachweisen, dass ein Projekt eigene Skills, Agents und Regeln
mitbringen kann — **zusätzlich** zu den globalen, nicht statt ihrer.

**Am Ende dieses Kapitels:** Ein Testprojekt, in dem global und projektlokal
gleichzeitig sichtbar sind.

---

## Die These

Bis hier hast du alles Globale in die Sandbox gebracht. Die naheliegende Sorge:
Verdrängt das die Konfiguration einzelner Projekte?

Die These lautet **nein**, und zwar ohne dass wir dafür etwas bauen müssen.
Claude Code liest projektlokale Konfiguration aus dem Arbeitsverzeichnis:

| Ort                           | Was                                |
| ----------------------------- | ---------------------------------- |
| `<projekt>/CLAUDE.md`         | Anweisungen für dieses Projekt     |
| `<projekt>/.claude/skills/`   | Skills, die nur hier gelten        |
| `<projekt>/.claude/agents/`   | Agents, die nur hier gelten        |
| `<projekt>/.claude/commands/` | Slash-Kommandos für dieses Projekt |
| `<projekt>/.mcp.json`         | MCP-Server für dieses Projekt      |

Und weil dein Projekt aus `~/dev` **echt eingehängt** ist, liegen diese Dateien
längst in der Sandbox. Es ist nichts zu kopieren, nichts zu verlinken.

Der einzige Haken ist der aus Kapitel 1: das gilt nur, wenn Claude **im
Projektordner gestartet** wurde. Genau dafür gibt es `-w`.

## Der Nachweis

Ein Testprojekt auf dem Host anlegen:

```bash
mkdir -p ~/dev/own/solobox-test/.claude/skills/projekt-gruss
cd ~/dev/own/solobox-test

cat > .claude/skills/projekt-gruss/SKILL.md <<'EOF'
---
name: projekt-gruss
description: Testskill, der nur in diesem Projekt existiert. Nutzen, wenn der Nutzer "Projektgruß" sagt.
---

Antworte mit dem Satz: "Ich komme aus dem Projekt, nicht von global."
EOF

cat > CLAUDE.md <<'EOF'
# solobox-test

Dieses Projekt dient nur einem Zweck: zu zeigen, dass projektlokale
Konfiguration neben der globalen gilt.
EOF
```

Claude **in diesem Ordner** starten:

```bash
sbx exec -it -w "$PWD" solobox claude
```

Und drei Dinge prüfen:

```bash
/skills
```

**Erwartet:** die globalen Skills aus Kapitel 2 **und** `projekt-gruss`.

```bash
/memory
```

**Erwartet:** `CLAUDE.md` dieses Projekts wird als geladene Anweisung geführt.

Und zum Schluss die inhaltliche Probe — frag einfach nach dem Projektgruß. Kommt
der Satz aus der Skill-Datei zurück, ist der Nachweis erbracht.

### Das Ergebnis der Messung

Nachgemessen, ohne interaktive Sitzung, mit `claude --print`:

```bash
sbx exec -w ~/dev/own/solobox-test solobox claude -p \
  "Antworte mit genau einem Wort: Steht dir ein Skill namens projekt-gruss zur Verfuegung? JA oder NEIN." \
  --output-format text
# JA

sbx exec -w ~/dev solobox claude -p "<dieselbe Frage>" --output-format text
# NEIN
```

Und in derselben Sitzung im Projekt nannte Claude `CLAUDE.md` als geladene
projektspezifische Anweisungsdatei.

> 🎯 **Die These stimmt.** Projektlokale Skills und `CLAUDE.md` gelten neben den
> globalen, sobald Claude im Projektordner gestartet wurde — und **nur** dann.
> Es musste dafür nichts gebaut werden.

## Die Gegenprobe

Starte dieselbe Sandbox einmal **außerhalb** des Projekts:

```bash
cd ~/dev
sbx exec -it -w "$PWD" solobox claude
```

```bash
/skills
```

**Erwartet:** die globalen Skills — `projekt-gruss` fehlt.

Das ist kein Fehler, sondern der Beweis, dass die Projektbindung am
Arbeitsverzeichnis hängt. Und es ist der Grund, warum `solobox up` das aktuelle
Verzeichnis nimmt statt immer im Primary Workspace zu starten.

## ⚠️ Wenn der projektlokale Skill nicht auftaucht

Dann gilt die These für Skills nicht (für `CLAUDE.md` gilt sie in jedem Fall),
und die Reihenfolge der Prüfung ist:

1. **Wurde wirklich im Projekt gestartet?** In der Sitzung `/status` — dort steht
   das Arbeitsverzeichnis. Steht dort `~/dev`, war es der Primary Workspace.
2. **Liegt die Datei am richtigen Fleck?** `.claude/skills/<name>/SKILL.md`, mit
   `name:` und `description:` im Frontmatter. Ohne `description` wird ein Skill
   nicht angeboten.
3. **Sieht die Sandbox die Datei?**

    ```bash
    sbx exec solobox ls ~/dev/own/solobox-test/.claude/skills
    ```

Bleibt es dabei, ist das der eine Punkt, an dem solobox etwas dazubauen müsste:
ein Kommando, das projektlokale Skills beim Start in den Store der Sandbox
spiegelt. Trag das Ergebnis in [troubleshooting.md](../troubleshooting.md) nach,
bevor du etwas baust — die einfachste Lösung ist immer noch, keine zu brauchen.

## Aufräumen

```bash
rm -rf ~/dev/own/solobox-test
```

---

➡️ **Weiter mit [Kapitel 6 — Der Wrapper](06-der-wrapper.md)**
