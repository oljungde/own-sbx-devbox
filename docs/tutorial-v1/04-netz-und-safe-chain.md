# Kapitel 4 — Netz und Safe Chain

**Ziel:** Verstehen, wie die Sandbox nach außen telefoniert — und warum ein
`npm install` gefährlicher ist, als die meisten denken.

**Am Ende dieses Kapitels:** Eine Sandbox mit einer bewusst kurzen Erlaubnisliste
und aktivem Malware-Schutz.

---

## Teil 1: Das Netz

### Global und pro Sandbox

`sbx` kennt zwei Ebenen von Netzwerkregeln:

```bash
# global — gilt für ALLE Sandboxes auf diesem Rechner
sbx policy allow network example.com

# pro Sandbox — gilt nur für diese eine
sbx policy allow network --sandbox devbox-lernen example.com
```

**Wir benutzen ausschließlich die zweite Variante.** Der Grund ist praktisch:
Wenn auf deinem Rechner noch ein anderes Sandbox-Setup läuft (beruflich zum
Beispiel), verändert eine globale Regel dessen Policy mit. Eine sandbox-scoped
Regel kann das nicht.

### Die Grundliste

```bash
for host in \
  api.anthropic.com \
  '*.claude.ai' \
  github.com \
  '*.githubusercontent.com' \
  '*.npmjs.org' \
  pypi.org \
  files.pythonhosted.org \
  '*.astral.sh' \
  '*.aikido.dev'
do
  sbx policy allow network --sandbox devbox-lernen "$host"
done
```

Neun Einträge. Das ist bewusst wenig.

Man ist versucht, vorsorglich vierzig Hosts freizugeben, damit „alles läuft".
Genau das solltest du **nicht** tun. Ein fehlender Host ist kein Defekt, sondern
der Normalfall — und die Reaktion darauf ist eine Fähigkeit, die man nur durch
Üben lernt.

### Übung: einen Host vermissen

In der Sandbox:

```bash
curl -sS https://fonts.googleapis.com
# curl: (7) Failed to connect
```

Auf dem Host:

```bash
sbx policy allow network --sandbox devbox-lernen '*.googleapis.com'
```

Nochmal in der Sandbox — jetzt geht es. Regeln greifen sofort, ein Neustart der
Sandbox ist nicht nötig.

Aktuelle Regeln ansehen:

```bash
sbx policy ls devbox-lernen
```

---

## Teil 2: Safe Chain

### Wovor es schützt

Nicht vor schlechtem Code. Vor **Supply-Chain-Angriffen**.

Das Muster ist immer gleich:

1. Jemand übernimmt per Phishing den npm-Account eines Maintainers.
2. Er veröffentlicht eine vergiftete Version eines Pakets mit Millionen
   Downloads — `chalk`, `debug`, `event-stream` waren reale Fälle.
3. Du tippst `npm install` für etwas *ganz anderes*. Das vergiftete Paket kommt
   als **tiefe Abhängigkeit** mit, die du nie selbst genannt hast.
4. Ein `postinstall`-Script läuft **mit deinen Rechten**: liest `~/.ssh`,
   Tokens aus `~/.npmrc`, Umgebungsvariablen, Krypto-Wallets — und schickt sie weg.

Du merkst nichts. Das Paket funktioniert ja.

### „Aber ich bin doch in einer Sandbox"

Ein berechtigter Einwand. Drei Gegenargumente:

1. Die Sandbox hat eine **Luke zu deinem echten Code** (Bind-Mount). Was dort
   manipuliert wird, ist echt manipuliert.
2. Sie kann **`git push`**. Kompromittierter Code landet im Remote — und damit
   bei allen anderen.
3. Ein **Agent installiert Pakete viel unbedarfter als du**. Er tippt
   `npm i <paket>`, wenn der Name plausibel klingt. Genau da greift
   Typosquatting.

Sandbox und Safe Chain sind zwei Schichten, keine Alternativen.

### Wie es in unserem Image funktioniert

Im Dockerfile (Schritt 8) haben wir für `npm`, `npx`, `pnpm`, `pnpx`, `uv` und
`uvx` je einen kleinen Shim in `/opt/safe-chain/shims` gebaut:

```sh
#!/bin/sh
PATH="$(printf "%s" "$PATH" | sed -e "s|/opt/safe-chain/shims:||g")"
export PATH
if command -v aikido-npm >/dev/null 2>&1; then
  exec aikido-npm "$@"
else
  echo "Warnung: safe-chain fehlt — npm läuft ungeschützt." >&2
  exec npm "$@"
fi
```

Drei Details, die es wert sind:

- Die `sed`-Zeile nimmt das Shim-Verzeichnis aus dem PATH, **bevor** das echte
  Werkzeug gerufen wird. Ohne das würde `aikido-npm` intern wieder unseren
  `npm`-Shim finden und sich endlos selbst aufrufen.
- Der `else`-Zweig ist eine bewusste Entscheidung: Ist Safe Chain kaputt, läuft
  `npm` trotzdem — aber mit sichtbarer Warnung. Ein Werkzeug, das im Fehlerfall
  einfach stillsteht, wird umgangen.
- Der Shim wird nur wirksam, weil `/etc/sandbox-persistent.sh` sein Verzeichnis
  vorne auf den PATH legt.

### Testen

Es gibt ein harmloses Köderpaket:

```bash
npm install safe-chain-test
```

Das **muss** blockiert werden. Passiert nichts, ist der Schutz nicht aktiv —
prüfe mit `echo $PATH | tr : '\n' | head -3`, ob `/opt/safe-chain/shims` ganz
vorne steht.

### Abschalten

Safe Chain braucht `*.aikido.dev` und kostet etwas Zeit pro Installation.
Manchmal willst du das nicht:

```bash
# einmalig für einen Befehl
DEVBOX_SAFE_CHAIN=0 npm install

# dauerhaft in dieser Sandbox
echo 'export DEVBOX_SAFE_CHAIN=0' | sudo tee -a /etc/sandbox-persistent.sh
```

### Der ehrliche Nachsatz

Safe Chain ist ein Dienst eines Drittanbieters. Er sieht, **welche Pakete du
installierst**. Für einen Kurs ist das unkritisch, aber wissen solltest du es.

---

## Was du jetzt weißt

- Netzregeln immer `--sandbox`-scoped setzen.
- Eine kurze Erlaubnisliste ist ein Feature, kein Mangel.
- `npm install` führt fremden Code mit deinen Rechten aus — Safe Chain prüft
  vorher, die Sandbox begrenzt den Schaden. Beides zusammen.

---

➡️ **Weiter mit [Kapitel 5 — Mehrere Projekte](05-mehrere-projekte.md)**
