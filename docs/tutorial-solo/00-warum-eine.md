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
([Kapitel 2](../tutorial/02-eigenes-dockerfile.md) und
[Kapitel 3](../tutorial/03-bauen-und-laden.md)). Hier steht die fertige Fassung.
Sieh sie dir an — und vergleiche:

```bash
less solobox/Dockerfile
diff <(grep -c '' devbox/Dockerfile) <(grep -c '' solobox/Dockerfile) || true
```

Die erste Erkenntnis dieses Kapitels ist eine Enttäuschung:

> 🎯 **Die beiden Varianten unterscheiden sich fast nicht im Image. Sie
> unterscheiden sich im Wrapper.**

Beide bringen Python 3.10, 3.12 und 3.14 mit (3.12 als Standard, `uv` wählt per
`.python-version` automatisch), Node 24, pnpm 10, Playwright mit Chromium, `jq`,
`git`, `gh`, `ripgrep` und Aikido Safe Chain. Was solobox braucht, brauchte
devbox auch — eine Sandbox für alle Projekte muss alles können, aber das galt
für den Dach-Ordner aus devbox-Kapitel 5 genauso.

Die drei echten Unterschiede:

**1. Safe Chain als Shell-Funktionen statt als PATH-Shims.**
devbox legt Shims nach `/opt/safe-chain/shims` und schaltet sie über eine
PATH-Zeile an und aus. solobox schreibt Shell-Funktionen direkt in
`/etc/sandbox-persistent.sh`. Beides fängt `npm`/`pnpm`/`uv` ab, bevor ein Paket
installiert wird; der Shim-Weg ist an- und abschaltbar, der Funktionsweg kürzer.

**2. `@playwright/mcp` ist vorgewärmt.**
Nur ein Eintrag im npm-Cache, damit der MCP-Server beim ersten Start nicht erst
lädt. Registriert wird er nicht — MCP-Server kommen in solobox über Plugins oder
`sbx mcp add` (Kapitel 4).

**3. Ein gcloud-Block liegt auskommentiert bereit.**
Er macht das Image spürbar größer, deshalb ist er aus. Wer ihn braucht, entfernt
die Kommentarzeichen — die zwei zugehörigen Hosts stehen daneben.

### Die Falle, in die diese Fassung zuerst getappt ist

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
chmod +x solobox/solobox.sh
```

Dann bauen. Das dauert beim ersten Mal einige Minuten:

```bash
./solobox/solobox.sh build
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

Kommt stattdessen `ERROR: Not authenticated to Docker`, fehlt `sbx login`. Das
sieht von außen genauso aus wie „Template nicht vorhanden" — deshalb sagt
`solobox status` bei dieser Lage ausdrücklich beides.

Und ein Blick ins Image, ohne dafür eine Sandbox anzulegen:

```bash
docker run --rm solobox/base:latest bash -lc \
  'python --version; python3.10 --version; python3.14 --version; node --version; pnpm --version; jq --version'
```

Erwartet: Python 3.12 als `python`, daneben 3.10 und 3.14, Node 24, pnpm 10 —
und bei `pnpm` **keine** Corepack-Download-Meldung.

---

➡️ **Weiter mit [Kapitel 1 — Die eine Sandbox](01-die-eine-sandbox.md)**
