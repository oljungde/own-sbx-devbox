# Kapitel 7 — Das Wrapper-Skript (und die Kür)

**Ziel:** Alles aus Kapitel 1 bis 6 in ein Skript packen, das man sich nicht
merken muss.

**Am Ende dieses Kapitels:** Ein Kommando pro Aufgabe — und du weißt genau, was
darunter passiert.

---

## Was wir bisher von Hand getippt haben

```bash
docker build -t devbox/base:latest -f Dockerfile .
docker save devbox/base:latest -o /tmp/devbox.tar
sbx template load /tmp/devbox.tar
rm /tmp/devbox.tar
sbx create -t devbox/base:latest --name devbox-privat claude \
  ~/dev/own ~/.claude/agents:ro ~/.claude/skills:ro ...
for host in ...; do sbx policy allow network --sandbox devbox-privat "$host"; done
sbx exec -d devbox-privat bash -c 'ln -sfn ...'
sbx run --name devbox-privat claude
```

Das ist nicht schwer — aber niemand tippt das jeden Tag. Genau dafür ist ein
Wrapper da.

> **Wichtig:** Der Wrapper erfindet nichts. Jede Zeile darin ist ein Kommando,
> das du in den letzten Kapiteln selbst getippt hast. Wenn er kaputtgeht, kommst
> du immer noch von Hand weiter.

## Der Wrapper

Lege [`devbox/devbox.sh`](../../devbox/devbox.sh) an. Die Datei ist knapp
250 Zeilen, davon gut die Hälfte Kommentare — **lies sie einmal durch**, sie ist
als Text gedacht.

Ausführbar machen:

```bash
chmod +x devbox/devbox.sh
```

## Die Kommandos

| Kommando | Ersetzt |
|---|---|
| `./devbox.sh build` | build + save + template load (Kapitel 3) |
| `./devbox.sh up [profil]` | create + policy + symlinks + run (Kapitel 3–6) |
| `./devbox.sh shell` | `sbx exec -it` |
| `./devbox.sh allow <host>` | `sbx policy allow network --sandbox` (Kapitel 4) |
| `./devbox.sh doctor` | prüft, ob alles bereitsteht |
| `./devbox.sh rm` | `sbx rm`, mit Warnung was verloren geht |

## Profile

Welche Ordner eine Sandbox sieht, steht nicht im Skript, sondern in einer
Konfigurationsdatei — bewusst **außerhalb** des Repos, damit persönliche Pfade
nicht versehentlich committet werden:

```bash
mkdir -p ~/.config/devbox
cp devbox/devbox.conf.example ~/.config/devbox/devbox.conf
$EDITOR ~/.config/devbox/devbox.conf
```

Ein Profil setzt drei Variablen:

```bash
privat)
  NAME="privat"                        # -> Sandbox "devbox-privat"
  WORKSPACES=( "$HOME/dev/own" )       # Dach-Ordner, erster = Startordner
  EXTRA_HOSTS=()                       # zusätzlich zur Grundliste
  ;;
```

Damit:

```bash
./devbox/devbox.sh doctor
./devbox/devbox.sh build
./devbox/devbox.sh up privat
```

## Zwei Stellen im Skript, die es wert sind

### Der Merkzettel für das Dockerfile

```bash
hash_file()     { printf '%s\n' "$STATE_DIR/image.hash"; }
current_hash()  { shasum -a 256 "$DOCKERFILE" | cut -d' ' -f1; }
```

`build` merkt sich den Fingerabdruck des Dockerfiles. Beim nächsten Aufruf wird
verglichen — ist er gleich, entfällt der ganze Vorgang. Das spart bei jedem
Start mehrere Minuten und ~6 GB Schreiblast.

### Netzregeln nur mit `--sandbox`

```bash
sbx policy allow network --sandbox "$SANDBOX" "$host"
```

Kein einziger globaler Aufruf im ganzen Skript. Ein anderes Sandbox-Setup auf
derselben Maschine bleibt garantiert unberührt.

---

## Die Kür: dasselbe deklarativ als Kit

`sbx` kann Konfiguration auch als YAML entgegennehmen, statt als Kommandofolge:

```yaml
schemaVersion: "2"
kind: sandbox
name: devbox
sandbox:
  image: "devbox/base:latest"
  entrypoint: [claude]
permissions:
  network:
    allow:
      - "api.anthropic.com:443"
      - "github.com:443"
```

Anwenden:

```bash
sbx create --kit ./devbox/kit/ --name devbox-kit claude ~/dev/own
```

Das ist deutlich schöner zu lesen als 100 Zeilen Bash. Warum ist es dann nicht
unser Hauptweg?

```
$ sbx kit --help
EXPERIMENTAL: this command may change or be removed in future releases.
```

Für Kursmaterial, das über Monate benutzt wird, ist „kann entfernt werden" ein
Risiko, das man nicht ins Fundament legt. Dazu kommt: Es gibt **nichts**, was
ein Kit kann und ein stabiles Kommando nicht:

| Kit | Stabile Entsprechung |
|---|---|
| `permissions.network` | `sbx policy allow network --sandbox` |
| `credentials` | `sbx secret` |
| Env-Variablen | `/etc/sandbox-persistent.sh` |
| Startup-Kommandos | `sbx exec -d` |

Das Kit ist also Zucker, kein Ermöglicher. Probier es aus — die Datei liegt
unter [`devbox/kit/kit.yaml`](../../devbox/kit/kit.yaml) —, aber baue nichts
darauf, was funktionieren *muss*.

---

## Geschafft

Du hast jetzt:

- ein eigenes Image mit deiner Toolchain
- eine Sandbox, die alle deine Projekte sieht
- deine globalen Skills und Agents darin
- Malware-Schutz beim Paketinstallieren
- ein bewusst kurzes Loch in der Firewall
- ein Skript, das das alles auf ein Kommando reduziert

**Und vor allem:** Du weißt, was jedes einzelne Stück davon tut. Wenn morgen
etwas kaputtgeht, kannst du es reparieren — nicht nur neu starten.

## Wie es weitergeht

Das Repo gehört dir. Naheliegende nächste Schritte:

- Eine zweite Image-Variante ohne Playwright (spart mehrere GB)
- Weitere Sprachen ins Dockerfile (Go, Rust, Java über SDKMAN)
- Ein Profil pro Kunde oder Kurs
- `sbx create --clone` ansehen: der Agent arbeitet auf einem containerinternen
  Klon des Repos statt auf deinen echten Dateien

---

📖 Weiterführend: [architektur.md](../architektur.md) erklärt das *Warum* hinter
den Entscheidungen, [troubleshooting.md](../troubleshooting.md) hilft, wenn
etwas klemmt.
