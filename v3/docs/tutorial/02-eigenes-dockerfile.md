# Kapitel 2 — Ein eigenes Dockerfile

Das Standard-Image kann Claude, aber nicht deine Projekte. Jetzt bauen wir das
Image, aus dem alle Projekt-Sandboxes entstehen.

Die fertige Fassung liegt als [`v3/Dockerfile`](../../Dockerfile) daneben. Hier
steht, warum sie so aussieht.

## Die Ausstattungsentscheidung — und warum sie hier anders ausfällt

Naheliegend wäre: schlank bauen, später nachlegen. Für diese Variante ist das
falsch, und zwar messbar:

Ein neues Template erreicht **bestehende** Sandboxes nicht. Fehlt dir später ein
Werkzeug, musst du das Image neu bauen **und jede Projekt-Sandbox löschen, neu
anlegen und dich neu anmelden**. Bei zehn Projekten ist „ich lege später nach"
kein kleiner Schritt, sondern ein Nachmittag.

Grössenordnungen, damit du selbst entscheiden kannst:

| Posten | Grösse |
| --- | --- |
| Playwright mit Chromium | ~1,5–2 GB |
| ein zusätzlicher Python über `uv` | ~150 MB |
| `poetry` und `ruff` | wenige zehn MB |

Der einzige schwere Posten ist Chromium. „Vollausstattung" ist also fast
dasselbe wie „schlank plus Chromium" — deshalb ist hier alles drin.

## Drei Begriffe, die man leicht verwechselt

- **Dockerfile** — der Text. Die Bauanleitung.
- **Image** — das Ergebnis des Baus. Unveränderlich.
- **Sandbox** — eine laufende Instanz eines Images, mit Mounts und Zustand.

Ein geändertes Dockerfile ändert kein Image. Ein neues Image ändert keine
laufende Sandbox. Beide Sätze sind der Grund für den Stempel weiter unten.

## Die Basis

```dockerfile
FROM docker/sandbox-templates:claude-code-docker
USER root
```

Am Ende muss `USER agent` stehen — zur Laufzeit läuft nicht root. Alles, was
dazwischen installiert wird, muss für `agent` **lesbar** sein, sonst installiert
er es sich zur Laufzeit noch einmal.

## Die Falle, die diese Fassung sich eingefangen hat

pnpm gehört installiert. Der elegante Weg wäre corepack — und er ist falsch:

```dockerfile
# NICHT so:
RUN corepack prepare pnpm@10.11.0 --activate
```

corepack legt seine Aktivierung im Cache des **Bau-Users** (root) unter
`/root/.cache/node/corepack` ab. Zur Laufzeit läuft `agent`, kommt dort nicht
heran und lädt sich beim ersten Aufruf still eine andere Version nach:

```
$ pnpm --version
! Corepack is about to download .../pnpm-11.21.0.tgz
11.21.0          <- nicht die festgelegte Version
```

Richtig ist das langweilige globale Paket — es landet in
`/usr/local/lib/node_modules` und gilt für alle Benutzer fest:

```dockerfile
RUN npm install -g pnpm@10.11.0
```

> 🎯 Prüfe nach jedem Bau `pnpm --version`. Eine Corepack-Download-Meldung ist
> das Symptom.

## Safe Chain: warum es Shims sein müssen

Aikido Safe Chain prüft Pakete auf Schadcode, bevor sie installiert werden. Der
Installer bietet an, Shell-Funktionen einzurichten. Das ist eine
Sicherheitslücke, nachgemessen:

Eine Shell-Funktion existiert nur **in** der Shell. Jeder Aufruf, der `npm` als
Programm startet, geht daran vorbei:

```bash
timeout 60 npm install boesartig      # timeout startet die Binärdatei
env npm install boesartig             # env ebenso
xargs -n1 npm install < liste         # xargs ebenso
sbx exec sbx-claude-api npm install … # gar keine Shell dazwischen
```

Genau so ging das offizielle Testpaket `safe-chain-test` durch, während derselbe
Befehl ohne `timeout` blockiert wurde. Deshalb baut das Dockerfile echte Dateien
in `/opt/safe-chain/shims` und stellt sie über eine einzige PATH-Zeile voran.
Der Schalter dafür ist `SBX_CLAUDE_SAFE_CHAIN=0`.

## Der Stempel

Am **Ende** des Dockerfiles:

```dockerfile
ARG SBX_CLAUDE_STAMP=unbekannt
LABEL sbx-claude.dockerfile-sha=$SBX_CLAUDE_STAMP
RUN printf '%s\n' "$SBX_CLAUDE_STAMP" > /etc/sbx-claude-stamp
```

Damit trägt jedes Image seine Herkunft selbst mit sich: als **Label** (vom Host
lesbar) und als **Datei** (aus der Sandbox lesbar). Der Wert ist der SHA-256 des
Dockerfile-**Textes** und kommt von aussen über `--build-arg` — er steht nirgends
in der Datei und kann seinen eigenen Hash nicht verändern.

Warum nicht einfach eine Merkdatei auf dem Host? Weil die fehlen, verloren gehen
oder auf einem anderen Rechner nie existiert haben kann. Der Stempel ist eine
beobachtbare Tatsache.

Warum am Ende? Ein neuer Stempelwert entwertet den Build-Cache ab der Zeile, in
der er zuerst benutzt wird. Weiter oben würde jede Dockerfile-Änderung das
Chromium- und Python-Kapitel neu bauen.

## Bauen und in den sbx-Store bringen

```bash
docker build -t sbx-claude/base:latest -f v3/Dockerfile \
  --build-arg SBX_CLAUDE_STAMP="$(shasum -a 256 v3/Dockerfile | cut -d' ' -f1)" \
  v3/
```

Und jetzt der Umweg, der alle überrascht:

```bash
docker save sbx-claude/base:latest -o /tmp/sbx-claude.tar
sbx template load /tmp/sbx-claude.tar
sbx template ls
```

> ⚠️ `sbx template build` gibt es **nicht**. Der sbx-Runtime hat einen eigenen
> Image-Store, getrennt von Docker Desktop — ein lokal gebautes Image kennt er
> nicht. Der komplette Tarball geht bei **jedem** Bau hinüber, deshalb dauert
> dieser Schritt Minuten. Der Wrapper macht daraus einen Befehl.

## Prüfen

```bash
docker run --rm sbx-claude/base:latest bash -lc \
  'python --version; python3.10 --version; python3.14 --version; pnpm --version; gcc --version | head -1; gh --version; ruff --version'
```

Erwartet: 3.12 als Standard, alle drei Pythons einzeln aufrufbar, pnpm **ohne**
Corepack-Meldung, ein Compiler (Python 3.14 braucht ihn für Pakete ohne Wheel),
`gh` und `ruff`.

Weiter mit [Kapitel 3](03-netz.md).
