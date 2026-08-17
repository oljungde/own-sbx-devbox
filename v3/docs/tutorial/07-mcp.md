# Kapitel 7 — MCP-Server

MCP-Server geben Claude Werkzeuge, die über Dateien und Shell hinausgehen. In
diesem Aufbau kommen sie aus zwei verschiedenen Richtungen, und die verwechselt
man leicht.

## Zwei Herkünfte, zwei Wege

| Herkunft | Wo der Server läuft | Was du tun musst |
| --- | --- | --- |
| aus einem **Plugin** | **im** Container, von Claude selbst gestartet | nichts — nur Netz freigeben |
| **eigenständig**, per `sbx mcp add` | **aussen**, sbx reicht ihn über sein Gateway hinein | Name in `MCP_SERVERS` |

## Weg 1: Plugin-Server

Aktive Plugins bringen ihre `.mcp.json` mit; sie sind über den `plugins`-Mount
aus Kapitel 4 in der Sandbox sichtbar, und Claude startet die Server selbst. Es
gibt **nichts** zu registrieren.

Was sie brauchen, ist Netz — und je nach Transportart etwas Verschiedenes:

| Server | Transport | Braucht im Container |
| --- | --- | --- |
| grepika | **stdio** (`npx @agentika/grepika`) | Node und `*.npmjs.org` für den Nachladeschritt |
| atlassian | **http** | Egress zu `*.atlassian.com` plus OAuth |
| figma | **http** | Egress zu `*.figma.com` plus OAuth |

Node ist im Image, die drei Hosts stehen in `BASE_HOSTS`. Deshalb funktionieren
sie ohne Zutun.

> 🎯 Der Unterschied stdio gegen http ist der, an dem man beim Fehlersuchen
> ansetzt. Ein stdio-Server, der `npx` benutzt, scheitert an einem fehlenden
> Node **oder** an einer blockierten Registry. Ein http-Server scheitert an
> Egress **oder** an fehlender Anmeldung.

## Weg 2: Eigenständige Server über sbx' Gateway

Registriert wird auf dem **Host**, geladen in die **Sandbox**:

```bash
# einmal auf dem Host
sbx mcp add linear --url https://mcp.linear.app/mcp
sbx mcp auth linear
sbx mcp ls
sbx mcp inspect linear

# pro Projekt-Sandbox
sbx mcp load linear --sandbox sbx-claude-api
```

Der Wrapper macht den zweiten Schritt für dich, wenn der Name in `MCP_SERVERS`
steht. Bei einer Box pro Projekt ist das ein Vorteil: du entscheidest pro
Projekt, welche Werkzeuge es überhaupt sieht.

Laut Dokumentation sieht eine **laufende** Sitzung die neuen Werkzeuge sofort
(über `tools/list_changed`) — ein Neustart ist nicht nötig.

## ⚠️ Der Weg, den wir nicht nehmen

`sbx mcp add` kann auch lokale Prozesse starten:

```bash
sbx mcp add github --command npx --args @modelcontextprotocol/server-github
```

Die Hilfe sagt dazu wörtlich, dass diese Server „as a subprocess on the HOST,
outside the sandbox" laufen. Damit hättest du einen Prozess mit deinen Rechten,
gesteuert vom Agenten in der Sandbox — ein Loch in genau der Wand, die dieses
Setup baut. `sbx-claude` benutzt das nicht.

Wenn du einen stdio-Server brauchst, gehört er **in** das Image (dann startet ihn
Claude im Container) oder er kommt als http-Server über das Gateway.

## Was mit `--static-mcp` ist

`sbx create --static-mcp notion,atlassian` legt beim Anlegen eine feste MCP-Menge
fest, die sich später nicht ändern lässt. Für dieses Setup ist das die falsche
Richtung: Mounts sind schon eine Ein-Weg-Entscheidung, und eine zweite wollen wir
nicht. `sbx mcp load` bleibt flexibel.

## Claude-eigene Connectors

Die Connectors, die du in der Claude-Oberfläche verbindest (Notion, Linear, Asana
und so weiter), laufen über claude.ai und brauchen weder `sbx mcp` noch einen
Eintrag hier — nur `*.claude.ai` im Netz, und das steht in `BASE_HOSTS`.

## Prüfen

In der Sandbox:

```
/mcp
```

Steht ein Server auf `failed` oder ewig auf `connecting`, ist die Netz-Policy die
mit Abstand häufigste Ursache:

```bash
sbx policy ls sbx-claude-api
sbx policy log sbx-claude-api
sbx policy check network --sandbox sbx-claude-api mcp.linear.app
```

Weiter mit [Kapitel 8](08-der-wrapper.md).
