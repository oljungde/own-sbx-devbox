# Kapitel 0 — Warum eine statt viele

**Ziel:** Verstehen, welchen Handel du hier eingehst — und das Image bauen.

**Am Ende dieses Kapitels:** Ein Template `solobox/base:latest` im sbx-Store.

---

## Der Unterschied in einem Satz

devbox fragt „welches Profil?". solobox fragt nichts.

Bei devbox entscheidest du pro Sandbox, was sie sieht und mitbringt. Das ist
sauber und trennscharf — und es ist Arbeit. Jedes neue Vorhaben will ein Profil,
jede Sandbox will einen eigenen Login, und deine Skills liegen entweder in jedem
Projekt noch einmal oder gar nicht.

solobox dreht das um: **eine** Sandbox, **ein** Login, und darin liegt alles, was
du auf dem Host global eingerichtet hast — Skills, Agents, Commands, Rules,
Hooks, Plugins.

## Was du dafür aufgibst

Das gehört an den Anfang, nicht ans Ende:

| Du verlierst                           | Warum                                                |
| -------------------------------------- | ---------------------------------------------------- |
| Trennung zwischen privat und beruflich | eine Sandbox sieht alles unter deiner Wurzel         |
| Getrennte Netzregeln pro Vorhaben      | eine Regelliste für alles                            |
| Getrennten Laufzeitzustand             | globale npm-Pakete beißen sich, wenn sie sich beißen |
| Die Wahl beim zweiten Mal              | Workspaces stehen beim Anlegen fest (Kapitel 1)      |

Dazu kommt eine Entscheidung, die du bewusst treffen solltest: solobox schreibt
deine globalen Skills in einen Store, den sich **alle** Sandboxes dieser Maschine
teilen. Auf deinem eigenen Rechner ist das genau die Bequemlichkeit, die du
willst. Auf einem geteilten Rechner ist es ein Seitenkanal. Kapitel 2 zeigt
beides und den Schalter dafür.

Wenn dich das stört: Variante 1 ist nicht schlechter, sie ist anders. Beide
liegen in diesem Repo nebeneinander und stören sich nicht.

## Das Dockerfile — und warum es fast dasselbe ist

Wie man ein Dockerfile für `sbx` schreibt, steht im devbox-Tutorial
([Kapitel 2](../tutorial-v1/02-eigenes-dockerfile.md) und
[Kapitel 3](../tutorial-v1/03-bauen-und-laden.md)). Hier steht die fertige Fassung.
Sieh sie dir an — und vergleiche:

```bash
less v2/Dockerfile
diff <(grep -c '' v1/Dockerfile) <(grep -c '' v2/Dockerfile) || true
```

Die erste Erkenntnis dieses Kapitels ist eine Enttäuschung:

> 🎯 **Die beiden Varianten unterscheiden sich fast nicht im Image. Sie
> unterscheiden sich im Wrapper.**

Beide bringen Python 3.10, 3.12 und 3.14 mit (3.12 als Standard, `uv` wählt per
`.python-version` automatisch), Node 24, pnpm 10, Playwright mit Chromium, `jq`,
`git`, `gh`, `ripgrep` und Aikido Safe Chain. Was solobox braucht, brauchte
devbox auch — eine Sandbox für alle Projekte muss alles können, aber das galt
für den Dach-Ordner aus devbox-Kapitel 5 genauso.

Die zwei echten Unterschiede:

**1. `@playwright/mcp` ist vorgewärmt.**
Nur ein Eintrag im npm-Cache, damit der MCP-Server beim ersten Start nicht erst
lädt. Registriert wird er nicht — MCP-Server kommen in solobox über Plugins oder
`sbx mcp add` (Kapitel 4).

**2. Ein gcloud-Block liegt auskommentiert bereit.**
Er macht das Image spürbar größer, deshalb ist er aus. Wer ihn braucht, entfernt
die Kommentarzeichen — die zwei zugehörigen Hosts stehen daneben.

Der Schalter für Safe Chain heißt hier `SOLOBOX_SAFE_CHAIN` statt
`DEVBOX_SAFE_CHAIN`, damit sich die beiden Varianten auf einer Maschine nicht in
die Quere kommen. Ansonsten ist der Schutz identisch aufgebaut — und das ist,
wie der nächste Abschnitt zeigt, kein Zufall, sondern das Ergebnis eines
misslungenen Versuchs.

## Safe Chain: warum es Shims sein müssen

Der Schutz vor Schadcode in Paketen liegt in beiden Varianten als **Shim** unter
`/opt/safe-chain/shims` und kommt über eine PATH-Zeile in
`/etc/sandbox-persistent.sh` zum Zug.

Die erste Fassung dieses Images machte es anders — mit Shell-Funktionen, die
`npm`, `pnpm` und `uv` abfangen. Das sieht kürzer aus und funktioniert im
Alltag. Prüf zuerst, dass der Schutz überhaupt greift:

```bash
sbx exec solobox bash -lc 'cd /tmp && mkdir -p sc && cd sc && npm init -y >/dev/null && npm install safe-chain-test'
```

```text
✖ Safe-chain: Malicious changes detected:
 - safe-chain-test@0.0.1-security
Safe-chain: Exiting without installing malicious packages.
```

### ⚠️ Der Test, der zu leicht besteht

Genau hier ist beim Bauen dieses Repos etwas schiefgegangen. Derselbe Test, nur
mit einer Zeitbegrenzung davor:

```bash
timeout 120 npm install safe-chain-test
# added 1 package, and audited 2 packages in 679ms
# found 0 vulnerabilities
```

**Das Schadpaket wurde installiert.** Nicht weil Safe Chain versagt hätte,
sondern weil eine Shell-**Funktion** nur in der Shell existiert. `timeout`
startet ein *Programm* — und eine Funktion kann es gar nicht aufrufen. Dieselbe
Lücke hat jeder Aufruf, bei dem kein Shell-Wort ausgewertet wird:

```bash
timeout 60 npm install boesartig       # timeout startet die Binärdatei
env npm install boesartig              # env ebenso
xargs -n1 npm install < liste.txt      # xargs ebenso
sbx exec solobox npm install ...       # gar keine Shell dazwischen
```

Ein Schutz, den man mit einem vorangestellten `env` aushebelt, ist keiner.

### Deshalb Shims

Ein Shim ist eine echte Datei unter `/opt/safe-chain/shims/npm`, die auf dem
`PATH` **vor** dem echten `npm` steht. Damit greift er auch dort, wo es keine
Shell gibt. Nachgemessen im fertigen Image:

```bash
docker run --rm solobox/base:latest bash -lc 'command -v npm; type -t npm'
# /opt/safe-chain/shims/npm
# file        <- eine Datei, keine Funktion
```

Und alle drei Varianten werden jetzt geblockt:

| Aufruf | mit Funktion | mit Shim |
| --- | --- | --- |
| `npm install safe-chain-test` | blockiert | blockiert |
| `timeout 120 npm install …` | **durchgelassen** | blockiert |
| `env npm install …` | **durchgelassen** | blockiert |

> 🎯 **Eine Shell-Funktion ist Bequemlichkeit, kein Schutzmechanismus.** Wer
> etwas abfangen will, muss es dort abfangen, wo Programme gesucht werden — im
> `PATH`.

Jeder Shim nimmt das Shim-Verzeichnis übrigens per `sed` aus dem `PATH`, bevor
er das echte Werkzeug aufruft. Ohne das fände `aikido-npm` intern wieder unseren
`npm`-Shim und riefe sich endlos selbst auf.

Abschalten, wenn Safe Chain einmal im Weg steht:

```bash
export SOLOBOX_SAFE_CHAIN=0
```

## Die zweite Falle, in die diese Fassung getappt ist

Im Dockerfile steht bei pnpm ein ausdrückliches „bewusst **nicht** über
corepack". Der Grund ist gemessen, nicht theoretisch: `corepack prepare
--activate` legt seine Aktivierung im Cache des **Bau**-Benutzers (root) ab. Der
Laufzeit-Benutzer `agent` kommt dort nicht heran und lädt sich beim ersten
Aufruf still eine andere Version nach:

```bash
$ pnpm --version
! Corepack is about to download .../pnpm-11.21.0.tgz
11.21.0
```

Gepinnt war 10.11.0. Genau diese Ausgabe kam aus der ersten Fassung dieses
Images — deshalb steht dort jetzt ein schlichtes `npm install -g pnpm@10.11.0`.
Merke: Was beim Bauen als root funktioniert, muss zur Laufzeit als `agent` noch
lange nicht funktionieren.

## Bauen

Zuerst das Ausführbar-Bit setzen — frisch aus git geklonte Skripte haben es,
frisch geschriebene nicht immer:

```bash
chmod +x v2/solobox.sh
```

Dann bauen. Das dauert beim ersten Mal einige Minuten:

```bash
./v2/solobox.sh build
```

Was dabei passiert, ist genau das, was du in devbox-Kapitel 3 von Hand getippt
hast: `docker build`, dann `docker save` in eine tar-Datei, dann
`sbx template load`. Der Umweg über die tar-Datei ist nötig, weil der
Docker-Daemon, den `sbx` benutzt, **nicht** derselbe ist wie dein lokaler — er
sieht deine lokal gebauten Images nicht.

## Prüfen

```bash
sbx template ls | grep solobox
```

Erwartet: eine Zeile mit `docker.io/solobox/base` und Tag `latest`.

Oder in einem Rutsch, samt der Frage, ob überhaupt noch etwas zu tun ist:

```bash
./v2/solobox.sh check
```

Was dieses Kommando alles beantwortet, steht in
[Kapitel 6](06-der-wrapper.md#check--muss-ich-neu-bauen).

Kommt stattdessen `ERROR: Not authenticated to Docker`, fehlt `sbx login`. Das
sieht von außen genauso aus wie „Template nicht vorhanden" — deshalb sagt
`solobox status` bei dieser Lage ausdrücklich beides.

Und ein Blick ins Image, ohne dafür eine Sandbox anzulegen:

```bash
docker run --rm solobox/base:latest bash -lc \
  'python --version; python3.10 --version; python3.14 --version; node --version; pnpm --version; jq --version; command -v npm'
```

Erwartet: Python 3.12 als `python`, daneben 3.10 und 3.14, Node 24, pnpm 10 —
und bei `pnpm` **keine** Corepack-Download-Meldung. Die letzte Zeile muss
`/opt/safe-chain/shims/npm` sagen: dann steht der Malware-Schutz vor dem echten
`npm`.

---

➡️ **Weiter mit [Kapitel 1 — Die eine Sandbox](01-die-eine-sandbox.md)**
