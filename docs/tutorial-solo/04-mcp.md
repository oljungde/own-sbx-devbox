# Kapitel 4 — MCP-Server

**Ziel:** Deine MCP-Server in der Sandbox nutzen — die aus Plugins und die mit
OAuth-Anmeldung.

**Am Ende dieses Kapitels:** `/mcp` in der Sandbox zeigt dieselben Server wie auf
dem Host, soweit sie dort hingehören.

---

## Zwei Herkünfte, zwei Wege

| Herkunft | Beispiel | Weg in die Sandbox |
|---|---|---|
| Ein **Plugin** bringt ihn mit | grepika, Atlassian, Figma, Playwright | nichts zu tun — kommt mit `enabledPlugins` |
| Eigenständig registriert | Linear, Notion, ein eigener stdio-Server | `sbx mcp add` + `sbx mcp load` |

Was **nicht** funktioniert: die `~/.claude.json` des Hosts einhängen. Dort stehen
MCP-Einträge und Sitzungszustand in derselben Datei — und der Zustand hat in
einem Container nichts verloren.

## Weg 1: Plugin-Server

Die sind nach Kapitel 3 bereits da. Prüfen:

```bash
cd ~/dev/own/mein-projekt
sbx exec -it -w "$PWD" solobox claude
```

```
/mcp
```

Erwartet: die Server deiner aktiven Plugins.

**Zeigt `/mcp` einen Server als „failed" oder „connecting"**, ist die häufigste
Ursache nicht der Server, sondern das Netz. Ein MCP-Server, dessen Ziel nicht in
der Policy steht, startet trotzdem — er kommt nur nicht raus:

```bash
sbx policy ls solobox
```

Fehlt der Host, freigeben und die Sitzung neu starten:

```bash
sbx policy allow network --sandbox solobox '*.context7.com'
```

Dauerhaft wird das als `EXTRA_HOSTS` in der Konfiguration (Kapitel 6).

## Weg 2: eigenständige Server

Diese registrierst du **einmal auf dem Host**. Der Vorteil: bei OAuth-Servern
passiert die Anmeldung dort, im Browser, und nicht in jeder Sandbox neu.

```bash
# Remote-Server mit OAuth
sbx mcp add linear --url https://mcp.linear.app/mcp
sbx mcp auth linear

# Lokaler stdio-Server — geht genauso
sbx mcp add github --command npx --args @modelcontextprotocol/server-github

sbx mcp ls
```

Und dann in die **laufende** Sandbox hineinreichen:

```bash
sbx mcp load linear --sandbox solobox
```

Der Server läuft dabei **außerhalb** der Sandbox; `sbx` reicht ihn über sein
Gateway hinein. Eine laufende Claude-Sitzung bekommt die neuen Werkzeuge sofort
mit — ohne Neustart.

## Was mit `--static-mcp` ist

`sbx create` kennt ein `--static-mcp`, das eine feste MCP-Menge für die Sandbox
setzt. Für solobox ist das der falsche Weg: die Menge wird **beim Anlegen**
eingefroren, und beim Anlegen weißt du noch nicht, welche Server du in drei
Monaten brauchst. Bei einer Sandbox, die du genau einmal anlegst, wäre jede
Änderung daran ein Neuaufbau — also `sbx mcp load` bei jedem Start, das kostet
nichts.

## Claude-eigene Connectors

Was du auf claude.ai als Connector eingerichtet hast (Google Calendar, Figma,
Notion …), hängt an deinem **Konto**, nicht an dieser Maschine. In der Sandbox
meldest du dich mit demselben Konto an — die Connectors sind also da, sobald du
angemeldet bist. Freigeschaltet sein muss trotzdem der Host, über den sie reden.

## Prüfen

```
/mcp
```

Erwartet: Plugin-Server plus alles, was du per `sbx mcp load` hineingereicht
hast.

Kurzdiagnose, wenn etwas fehlt:

| Symptom | Ursache | Prüfen mit |
|---|---|---|
| Server fehlt ganz | Plugin nicht aktiv, oder nicht geladen | `/plugin`, `sbx mcp ls` |
| Server da, Werkzeuge scheitern | Host nicht freigegeben | `sbx policy ls solobox` |
| Server verlangt Anmeldung | OAuth auf dem Host fehlt | `sbx mcp auth <name>` |

---

➡️ **Weiter mit [Kapitel 5 — Projektlokale Ergänzungen](05-projektlokal.md)**
