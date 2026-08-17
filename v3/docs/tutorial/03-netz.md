# Kapitel 3 — Netz

Die Sandbox darf standardmässig nichts. Das ist die Grenze, die als einzige gegen
**Exfiltration** wirkt — dagegen, dass Daten hinausgehen. Hier legst du fest, mit
welchen Adressen geredet werden darf.

## Das Kommando heisst `policy`, nicht `network`

```bash
sbx policy allow network --sandbox sbx-claude-api "api.example.com"
sbx policy allow network --sandbox sbx-claude-api "api.example.com,cdn.example.com"
sbx policy allow network --sandbox sbx-claude-api "*.npmjs.org"
sbx policy allow network --sandbox sbx-claude-api "example.com:443"
```

Kommagetrennte Listen, Wildcard-Subdomains, optionaler Port. Ansehen und prüfen:

```bash
sbx policy ls sbx-claude-api
sbx policy ls --wide
sbx policy check network --sandbox sbx-claude-api api.anthropic.com
sbx policy log sbx-claude-api          # was wurde erlaubt, was blockiert
```

`sbx policy log` ist das erste Werkzeug, wenn etwas „einfach nicht geht".

## ⚠️ Immer mit `--sandbox`

Ohne `--sandbox` gilt eine Regel **global für alle Sandboxes**. Auf derselben
Maschine kann ein fremdes sbx-Setup laufen, dessen Policy du damit mitveränderst.
`sbx-claude` setzt deshalb ausnahmslos jede Regel mit `--sandbox`.

## Was beim `create` geht und was nicht

```bash
sbx create --deny-network ads.example.com --name … claude …   # geht
sbx create --allow-network api.example.com --name … claude …  # geht NICHT
```

Ein Deny beim Anlegen ist erlaubt, ein Allow nicht — die Hilfe begründet es
damit, dass ein lokales Deny die Freigabe nur verengen, nie erweitern kann.
`--allow-network` gibt es nur in der Cloud-Variante. Skriptiertes Anlegen braucht
also immer einen zweiten Schritt mit `sbx policy allow network`.

## Die drei Ebenen

Es gibt keine `--from-file`-Option, also macht der Wrapper eine Schleife über
Bash-Arrays. Drei Ebenen, von aussen nach innen:

| Ebene | Wo | Für wen |
| --- | --- | --- |
| `BASE_HOSTS` | [`v3/sbx-claude.sh`](../../sbx-claude.sh) | alle Projekte, vom Repo vorgegeben |
| `EXTRA_HOSTS` | `~/.config/sbx-claude/sbx-claude.conf` | alle Projekte, von dir |
| `.sbx-claude-hosts` | im Projekt selbst | nur dieses Projekt |

Die Grundausstattung deckt Anthropic, claude.ai, GitHub, npm, PyPI, astral,
aikido, Playwright, context7, atlassian, figma und die Registries ab.

Für einen einzelnen Versuch:

```bash
sbx-claude allow packages.cloud.google.com
```

Das gilt nur, bis die Sandbox neu angelegt wird. Dauerhaft gehört der Host als
`EXTRA_HOSTS` in die Konfiguration.

## ⚠️ Warum die projektlokale Liste eine Rückfrage braucht

Die Datei `.sbx-claude-hosts` liegt im Repo — also genau dort, wo der Agent
schreiben darf. Er könnte sich selbst Hosts freigeben, und damit die einzige
Grenze aufziehen, die gegen Exfiltration wirkt. Bei einer Box pro Projekt ist
eine projektlokale Liste sinnvoll, still angewendet wäre sie ein Selbstbedienungsladen.

Deshalb: `sbx-claude up` zeigt neue Einträge, fragt einmal, und merkt die
Bestätigung ausserhalb des Projekts (in `~/.local/state/sbx-claude/`). Beim
nächsten Start wird nicht wieder gefragt — bei einem **neuen** Eintrag schon.

Beispiel einer solchen Datei:

```
# Zeilen mit # sind Kommentare
*.sentry.io
packages.cloud.google.com
```

## Was beim BAUEN gilt — und was nicht

Eine Verwechslung, die Zeit kostet: Was das Dockerfile beim Bauen aus dem Netz
holt, unterliegt **nicht** der sbx-Netzregel. Beim Bauen redet der Docker-Daemon,
nicht der Container. Die Regeln hier gelten für die **laufende** Sandbox.

## Probe

In der Sandbox:

```bash
sbx-claude shell
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com   # geht
curl -sS -o /dev/null -w '%{http_code}\n' https://example.org         # blockiert
exit
```

Und auf dem Host nachsehen, was passiert ist:

```bash
sbx policy log sbx-claude-probe-api
```

Weiter mit [Kapitel 4](04-globale-config.md).
