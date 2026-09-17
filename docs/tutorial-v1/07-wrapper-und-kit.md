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

Lege [`v1/devbox.sh`](../../v1/devbox.sh) an. Gut ein Viertel der Datei
sind Kommentare — **lies sie einmal durch**, sie ist als Text gedacht.

```bash
wc -l v1/devbox.sh                    # Umfang
grep -cE '^\s*#' v1/devbox.sh         # davon Kommentarzeilen
```

Ausführbar machen:

```bash
chmod +x v1/devbox.sh
```

## Die Kommandos

| Kommando                   | Ersetzt                                          |
| -------------------------- | ------------------------------------------------ |
| `./devbox.sh build`        | build + save + template load (Kapitel 3)         |
| `./devbox.sh up [profil]`  | create + policy + symlinks + run (Kapitel 3–6)   |
| `./devbox.sh shell`        | `sbx exec -it`                                   |
| `./devbox.sh allow <host>` | `sbx policy allow network --sandbox` (Kapitel 4) |
| `./devbox.sh status`       | `sbx ls` + `sbx template ls`, zusammengelesen    |
| `./devbox.sh update`       | `build --force` + der Abgleich aus Kapitel 3     |
| `./devbox.sh doctor`       | prüft, ob der Host alles bereithält              |
| `./devbox.sh rm`           | `sbx rm`, mit Warnung was verloren geht          |

`status` und `doctor` beantworten verschiedene Fragen: **doctor** fragt „ist mein
Host richtig eingerichtet?", **status** fragt „was läuft gerade?".

`update` ist die Antwort auf den Fallstrick aus [Kapitel 3](03-bauen-und-laden.md):
Ein neu gebautes Template erreicht eine bestehende Sandbox nicht. Weil `sbx ls`
nicht verrät, aus welchem Template eine Sandbox entstanden ist, schreibt der
Wrapper sich das beim Anlegen selbst auf — nach `~/.local/state/devbox/`:

```bash
$ ./v1/devbox.sh update
>> baue Image 'devbox/base:latest' ...
>> exportiere das Image (dauert bei mehreren GB einen Moment) ...
>> lade das Image in den sbx-Template-Store ...
>> fertig. Template 'devbox/base:latest' steht bereit.

>> prüfe, welche Sandboxes noch auf einem älteren Template sitzen ...
!!   devbox-privat — noch auf deadbeef1234 (neu ist aaaa11112222)

!! Ein neues Template erreicht eine bestehende Sandbox NICHT. Damit sie es
!! bekommt, muss sie einmal neu angelegt werden:
!!
!!     ./devbox.sh rm <profil> && ./devbox.sh up <profil>
```

## Profile

Welche Ordner eine Sandbox sieht, steht nicht im Skript, sondern in einer
Konfigurationsdatei — bewusst **außerhalb** des Repos, damit persönliche Pfade
nicht versehentlich committet werden:

```bash
mkdir -p ~/.config/devbox
cp v1/devbox.conf.example ~/.config/devbox/devbox.conf
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

Drei weitere sind optional und standardmäßig aus — `SHARE_ALL`, `MCP_SERVERS`
und `MCP_CONFIG`. Sie nehmen die Trennungen aus
[Kapitel 6](06-globale-und-lokale-config.md#alles-auf-einmal--und-was-es-kostet)
zurück und bringen Skills, Plugins und MCP-Server gleich beim Anlegen mit. Warum
das ein Profil-Schalter ist und keine Voreinstellung: Es ist eine Entscheidung
über die Grenze zu **fremden** Sandboxes, und die kann nur treffen, wer seine
Maschine kennt.

Damit:

```bash
./v1/devbox.sh doctor
./v1/devbox.sh build
./v1/devbox.sh up privat
```

## Der letzte Schritt: von überall aufrufbar

Bisher steht in allen Beispielen `./v1/devbox.sh`. Das funktioniert nur,
solange du im Repo-Wurzelverzeichnis stehst — und dort stehst du im Alltag
nie, sondern in einem Projektordner:

```bash
cd ~/dev/own/projekt-x
./v1/devbox.sh up          # No such file or directory
```

Das Skript selbst ist darauf vorbereitet. Es sucht sein Dockerfile nicht im
aktuellen Verzeichnis, sondern dort, wo es selbst liegt:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

Es ist also egal, von wo du es aufrufst — es fehlt nur ein kurzer Name.

### macOS und Linux

```bash
# macOS (zsh ist Standard) — Linux meist ~/.bashrc
echo 'alias devbox="$HOME/dev/own/devbox/v1/devbox.sh"' >> ~/.zshrc
source ~/.zshrc
```

Nutzt du auf macOS bash, gehört die Zeile in `~/.bash_profile` — die
Login-Shell liest `~/.bashrc` dort **nicht** automatisch.

Ab jetzt, aus jedem Verzeichnis:

```bash
devbox status
devbox up privat
```

> Ein Alias reicht hier, weil bash und zsh die Argumente einfach anhängen:
> `devbox up privat` wird zu `…/devbox.sh up privat`. In PowerShell gilt das
> **nicht** — dort braucht es eine Funktion. Siehe
> [Kapitel 0](00-vorbereitung.md#windows) und das
> [Cheat Sheet](../cheatsheet-v1.md#einen-alias-anlegen).

### Oder ohne Shell-Datei: ein Symlink im PATH

```bash
mkdir -p ~/.local/bin
ln -sfn ~/dev/own/devbox/v1/devbox.sh ~/.local/bin/devbox
```

Auf den meisten Linux-Distributionen ist `~/.local/bin` schon im `PATH`, auf
macOS meist nicht — dort einmalig:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Beides funktioniert. Der Symlink hat den kleinen Vorteil, dass er auch für
Skripte und Editoren sichtbar ist, nicht nur für deine interaktive Shell.

> **Und wo startet Claude dann?** Nicht in deinem aktuellen Ordner, sondern im
> Primary Workspace des Profils — dem ersten Pfad in `WORKSPACES`. Das ist
> Absicht: Die Sandbox ist projektübergreifend
> ([Kapitel 5](05-mehrere-projekte.md)). Innerhalb der Sandbox wechselst du mit
> `cd` in dein Projekt.

## Zwei Stellen im Skript, die es wert sind

### Der Merkzettel für das Dockerfile

```bash
hash_file()     { printf '%s\n' "$STATE_DIR/image.hash"; }
current_hash()  { shasum -a 256 "$DOCKERFILE" | cut -d' ' -f1; }
```

`build` merkt sich den Fingerabdruck des Dockerfiles. Beim nächsten Aufruf wird
verglichen — ist er gleich, entfällt der ganze Vorgang. Das spart bei jedem
Start mehrere Minuten und rund 1,4 GB Schreiblast für die Zwischendatei.

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
schemaVersion: '2'
kind: sandbox
name: devbox
sandbox:
    image: 'devbox/base:latest'
    entrypoint: [claude]
permissions:
    network:
        allow:
            - 'api.anthropic.com:443'
            - 'github.com:443'
```

Anwenden:

```bash
sbx create --kit ./v1/kit/ --name devbox-kit claude ~/dev/own
```

Das ist deutlich schöner zu lesen als 100 Zeilen Bash. Warum ist es dann nicht
unser Hauptweg?

```bash
$ sbx kit --help
EXPERIMENTAL: this command may change or be removed in future releases.
```

Für Kursmaterial, das über Monate benutzt wird, ist „kann entfernt werden" ein
Risiko, das man nicht ins Fundament legt. Dazu kommt: Es gibt **nichts**, was
ein Kit kann und ein stabiles Kommando nicht:

| Kit                   | Stabile Entsprechung                 |
| --------------------- | ------------------------------------ |
| `permissions.network` | `sbx policy allow network --sandbox` |
| `credentials`         | `sbx secret`                         |
| Env-Variablen         | `/etc/sandbox-persistent.sh`         |
| Startup-Kommandos     | `sbx exec -d`                        |

Das Kit ist also Zucker, kein Ermöglicher. Probier es aus — die Datei liegt
unter [`v1/kit/kit.yaml`](../../v1/kit/kit.yaml) —, aber baue nichts
darauf, was funktionieren _muss_.

---

## Geschafft

Du hast jetzt:

- ein eigenes Image mit deiner Toolchain
- eine Sandbox, die alle deine Projekte sieht
- deine globalen Skills und Agents darin
- Malware-Schutz beim Paketinstallieren
- ein bewusst kurzes Loch in der Firewall
- ein Skript, das das alles auf ein Kommando reduziert — aus jedem Verzeichnis

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

📖 Weiterführend: [cheatsheet-v1.md](../cheatsheet-v1.md) hat alle Kommandos auf einer
Seite (und zeigt, wie du dir einen `devbox`-Alias anlegst),
[architektur.md](../architektur.md) erklärt das _Warum_ hinter den
Entscheidungen, [troubleshooting.md](../troubleshooting.md) hilft, wenn etwas
klemmt.
