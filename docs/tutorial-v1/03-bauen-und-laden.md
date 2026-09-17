# Kapitel 3 — Bauen und laden

**Ziel:** Aus dem Dockerfile ein Image bauen, es `sbx` bekannt machen und eine
Sandbox daraus starten.

**Am Ende dieses Kapitels:** Deine erste eigene Sandbox mit voller Toolchain.

---

## Schritt 1: Bauen

```bash
cd ~/dev/own/devbox/v1
docker build -t devbox/base:latest -f Dockerfile .
```

Das dauert beim ersten Mal einige Minuten — Playwright lädt einen kompletten
Chromium, und drei Python-Interpreter wollen auch installiert werden. Das
fertige Image ist rund **6 GB**.

Der Punkt am Ende ist der _Build-Kontext_: das Verzeichnis, aus dem Docker
Dateien kopieren darf. Wir kopieren nichts, aber angeben muss man ihn trotzdem.

Prüfen:

```bash
docker images devbox/base
```

## Schritt 2: Der Umweg, der alle überrascht

Jetzt könnte man meinen, `sbx` sieht das Image einfach. Tut es nicht:

> The Docker daemon used by Docker Sandboxes pulls templates directly from a
> registry and **does not share the image store of your local Docker daemon.**

`sbx` hat seinen **eigenen** Docker-Daemon. Dein frisch gebautes Image liegt im
falschen. Es gibt zwei Wege hinüber:

| Weg                                                                  | Wann                                    |
| -------------------------------------------------------------------- | --------------------------------------- |
| Über eine Registry (`docker push`, dann `sbx create -t ghcr.io/...`) | Wenn du das Image im Team teilen willst |
| Über eine tar-Datei (`docker save` → `sbx template load`)            | Wenn du lokal baust — unser Fall        |

```bash
docker save devbox/base:latest -o /tmp/devbox.tar
sbx template load /tmp/devbox.tar
rm /tmp/devbox.tar
```

> 💡 Die tar-Datei ist **kleiner als das Image** — bei uns rund 1,4 GB gegenüber
> 5,9 GB, weil `docker save` die Layer komprimiert schreibt. Trotzdem: danach
> löschen. Der Wrapper in Kapitel 7 nimmt dir das ab und überspringt den ganzen
> Vorgang, solange sich das Dockerfile nicht geändert hat.

## Schritt 3: Sandbox anlegen

```bash
sbx create -t devbox/base:latest --name devbox-lernen claude ~/dev/lernen
```

Auseinandergenommen:

| Teil                    | Bedeutung                   |
| ----------------------- | --------------------------- |
| `-t devbox/base:latest` | aus welchem Template        |
| `--name devbox-lernen`  | wie die Sandbox heißt       |
| `claude`                | welcher Agent darin läuft   |
| `~/dev/lernen`          | welcher Ordner sichtbar ist |

> 💡 Der Name beginnt bewusst mit `devbox-`. Läuft auf deinem Rechner noch ein
> anderes Sandbox-Setup, kollidiert so nichts.

## Schritt 4: Starten und prüfen

```bash
sbx run --name devbox-lernen claude
```

Beim ersten Mal wieder anmelden (`claude auth login --claudeai`) — die Sandbox
ist neu, also ist auch der Login neu.

In einer zweiten Shell:

```bash
sbx exec -it devbox-lernen bash
```

Und die Abnahme:

```bash
python --version        # 3.12.x
uv python list --only-installed
poetry --version
ruff --version
pnpm --version          # 10.11.0, OHNE Download-Meldung
node --version
gh --version
jq --version
rg --version
gcc --version
```

Wenn `pnpm --version` eine Zeile wie _"Corepack is about to download…"_ zeigt,
ist etwas schiefgelaufen — siehe
[troubleshooting.md](../troubleshooting.md#pnpm-lädt-beim-ersten-aufruf-eine-andere-version-nach).

## Schritt 5: Die drei Pythons ausprobieren

```bash
cd ~/dev/lernen
mkdir alt && cd alt
echo "3.10" > .python-version
uv run python --version      # Python 3.10.x
cd .. && python --version    # Python 3.12.x — der Standard
```

Genau so soll es sein: **Der Standard gilt überall, das Projekt entscheidet
für sich.**

## Der Fallstrick: ein neues Template erreicht alte Sandboxes nicht

Angenommen, du ergänzt morgen Go im Dockerfile und baust neu:

```bash
docker build -t devbox/base:latest -f Dockerfile .
docker save devbox/base:latest -o /tmp/devbox.tar
sbx template load /tmp/devbox.tar
```

Danach startest du deine Sandbox — und `go version` sagt _command not found_.
Kein Fehler, sondern die Bauart: Eine Sandbox wird beim **Anlegen** aus dem
Template kopiert. Sie wird danach nie wieder daran angeglichen.

Damit die Sandbox das neue Template bekommt, muss sie neu angelegt werden:

```bash
sbx rm --force devbox-lernen
sbx create -t devbox/base:latest --name devbox-lernen claude ~/dev/lernen
```

Das kostet den Claude-Login und alles, was du zur Laufzeit _in_ der Sandbox
installiert hast. Deine Projektdateien liegen auf dem Host und bleiben unberührt.

> Genau diese Buchhaltung übernimmt später `./devbox.sh update`
> ([Kapitel 7](07-wrapper-und-kit.md)): Es baut neu und sagt dir, welche
> Sandboxes noch auf dem alten Template sitzen. Merken musst du dir das
> trotzdem — es ist der häufigste „aber ich hab doch neu gebaut"-Moment.

## Was du jetzt weißt

- Ein Image gehört deinem Docker, ein Template gehört `sbx` — dazwischen liegt
  `docker save` + `sbx template load`.
- Eine Sandbox entsteht aus einem Template und ist langlebig.
- Ein **neues Template erreicht eine bestehende Sandbox nicht.** Dafür braucht
  es `sbx rm` und ein neues `sbx create`.
- Der Build ist teuer, das Anlegen einer Sandbox ist billig. Deshalb: **ein
  Template, viele Sandboxes.**

---

➡️ **Weiter mit [Kapitel 4 — Netz und Safe Chain](04-netz-und-safe-chain.md)**
