# Cheat Sheet

Die kurze Fassung für den Alltag. Das _Warum_ steht in
[architektur.md](architektur.md), das _Wie kam es dazu_ im
[Tutorial](tutorial/README.md). Noch nichts installiert?
[Kapitel 0](tutorial/00-vorbereitung.md).

---

## Von Null bis ins Projekt

Einmal einrichten (Schritt 1–3), danach nur noch Schritt 4 und 5.

```bash
cd ~/dev/own/devbox

# 1  Profil anlegen — welche Ordner die Sandbox sieht
mkdir -p ~/.config/devbox
cp devbox/devbox.conf.example ~/.config/devbox/devbox.conf
$EDITOR ~/.config/devbox/devbox.conf     # WORKSPACES auf deinen Dach-Ordner

# 2  Host prüfen
./devbox/devbox.sh doctor                # nur Häkchen erwartet

# 3  Image bauen und als sbx-Template laden — einmal pro Maschine, ~6 GB
./devbox/devbox.sh build

# 4  Sandbox anlegen (beim ersten Mal) und Claude starten
./devbox/devbox.sh up privat

# 5  In der Sandbox ins Projekt wechseln
cd projekt-x
```

Claude startet im **Dach-Ordner**, nicht in deinem Projekt — die Sandbox ist
projektübergreifend. Deshalb Schritt 5.

### Mit und ohne Alias

Schritt 4 ist der einzige, den du täglich brauchst — und der einzige, bei dem
der Alias etwas ändert:

```bash
# ohne Alias — nur aus dem Repo-Wurzelverzeichnis
cd ~/dev/own/devbox && ./devbox/devbox.sh up privat

# mit Alias — aus jedem Verzeichnis
devbox up privat
```

Alias einmalig anlegen (macOS/zsh; Linux meist `~/.bashrc`):

```bash
echo 'alias devbox="$HOME/dev/own/devbox/devbox/devbox.sh"' >> ~/.zshrc
source ~/.zshrc
```

Windows und die Symlink-Variante: [unten](#einen-alias-anlegen).

---

## Täglich

| Befehl                | Wofür                                     |
| --------------------- | ----------------------------------------- |
| `devbox up privat`    | Sandbox starten, Claude öffnen            |
| `cd projekt-x`        | in der Sandbox ins Projekt                |
| `exit` / `Ctrl-D`     | raus — Sandbox läuft weiter, Login bleibt |
| `devbox status`       | was läuft, auf welchem Template           |
| `devbox allow <host>` | fehlenden Host freigeben                  |
| `devbox shell privat` | bash statt Claude                         |

Mehr braucht der Alltag nicht.

---

## Globales mitnehmen: Skills, Agents, Plugins, MCP

Der Wrapper hängt fünf Ordner aus `~/.claude` **read-only** in die Sandbox
(`CLAUDE_SHARED` in [devbox.sh](../devbox/devbox.sh#L47)). Vier davon werden
zusätzlich nach `/home/agent/.claude/` verlinkt — `skills` nicht, dort sitzt
schon der eigene Store von `sbx`.

| Was                    | Zustand in der Sandbox              | Was du tun musst                                    |
| ---------------------- | ----------------------------------- | --------------------------------------------------- |
| `agents`               | ✓ verlinkt, wird gefunden           | nichts                                              |
| `commands` (`/…`)      | ✓ verlinkt, wird gefunden           | nichts                                              |
| `rules`                | ✓ verlinkt, wird gefunden           | nichts                                              |
| `plugins`              | Ordner da, aber **nicht aktiviert** | projektlokal in `.claude/settings.json` einschalten |
| `skills`               | nur unter dem **Host-Pfad** lesbar  | in `.claude/skills/` des Projekts kopieren          |
| MCP-Server             | kommen **nicht** mit                | `.mcp.json` im Projekt oder `sbx mcp`               |
| `settings.json`, Login | bewusst nicht gemountet             | —                                                   |

Was mit Häkchen dasteht, setzt jedes `devbox up` neu. Nachsehen:

```bash
./devbox/devbox.sh shell privat
ls -la ~/.claude        # agents, commands, rules, plugins als Symlinks
```

Die drei unteren Zeilen kannst du dir sparen — mit einer bewussten Entscheidung:
[Alles sofort dabei](#alles-sofort-dabei-share_all).

### Skills

Sie liegen in der Sandbox unter ihrem **Host-Pfad**, nicht unter `~/.claude`:

```bash
ls /Users/DEINNAME/.claude/skills        # Linux/WSL: /home/DEINNAME/...
```

Den gewünschten Skill ins Projekt kopieren — dort findet Claude ihn zuverlässig,
und er ist nebenbei versioniert und im Team geteilt:

```bash
mkdir -p .claude/skills
cp -r /Users/DEINNAME/.claude/skills/mein-skill .claude/skills/
```

Warum nicht einfach verlinken: [architektur.md](architektur.md#der-sonderfall-skills).

Gilt **nur für eigene** Skills unter `~/.claude/skills`. Skills aus einem Plugin
nehmen einen anderen Weg — siehe gleich.

### Plugins

Der Ordner bringt die Registrierung mit (`installed_plugins.json`) und auch die
Marktplätze (`known_marketplaces.json`), nicht aber die _Aktivierung_ — die steht
in `settings.json`, und die mounten wir nicht. Mehr fehlt nicht:

```json
// <projekt>/.claude/settings.json
{
  "enabledPlugins": {
    "mattpocock-skills@claude-plugins-official": true
  }
}
```

Danach Claude in der Sandbox neu starten — `settings.json` wird beim Start
gelesen. Willst du das Plugin in **allen** Projekten einer Sandbox, lege dieselbe
Datei dort als `~/.claude/settings.json` an: ein echter Container-Pfad,
überlebt Neustarts, stirbt mit `rm`.

**Plugin-Skills umgehen den `skills`-Sonderfall.** Sie liegen nicht in
`~/.claude/skills`, sondern im Plugin selbst — also unter
`~/.claude/plugins/cache/<markt>/<plugin>/<version>/skills/`. Und `plugins` wird
verlinkt. Kopieren musst du hier deshalb nichts:

```bash
# in der Sandbox — der Inhalt ist schon da
ls ~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/*/skills
```

Aufgerufen werden sie mit dem Plugin als Präfix, z.B.
`/mattpocock-skills:code-review`.

> ⚠️ Der Mount ist **read-only**: `/plugin update` scheitert in der Sandbox.
> Aktualisiere auf dem Host — weil live gemountet und nicht kopiert wird, ist die
> neue Version sofort in der Sandbox, ohne Template-Neubau.

Bringt ein Plugin einen MCP-Server mit, gilt zusätzlich der nächste Abschnitt.

### MCP-Server

Deine Host-Registrierung kommt nicht mit. Zwei Wege:

**① `.mcp.json` im Projekt** — der Standardweg, versionierbar:

```json
{
  "mcpServers": {
    "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] }
  }
}
```

Dazu den Host freigeben, den der Server anspricht — sonst startet er und kommt
nicht raus:

```bash
./devbox/devbox.sh allow 'mcp.context7.com' privat
```

**② `sbx mcp` für Dienste mit OAuth** (Atlassian, Linear, Notion …). Der Server
läuft dann **außerhalb** der Sandbox, die Anmeldung passiert auf dem Host:

```bash
sbx mcp add linear --url https://mcp.linear.app/mcp
sbx mcp auth linear
sbx mcp load linear --sandbox devbox-privat
sbx mcp ls                               # was ist registriert
```

In der Claude-Session prüfen: `/mcp` listet die verbundenen Server.

### Alles sofort dabei (`SHARE_ALL`)

Wenn auf deiner Maschine **nur deine eigenen** Sandboxes laufen, ist die
Trennung oben Aufwand ohne Gegenwert. Drei Profil-Variablen nehmen sie zurück:

```bash
alles)
  NAME="alles"
  WORKSPACES=( "$HOME/dev/own" )
  EXTRA_HOSTS=( 'mcp.context7.com' )      # jeder MCP-Server braucht seinen Host

  SHARE_ALL=1                             # Skills kopieren + alle Plugins an
  MCP_SERVERS=( linear )                  # vorher: sbx mcp add/auth
  MCP_CONFIG="$HOME/.config/devbox/mcp.json"
  ;;
```

Was `devbox up alles` dann zusätzlich tut:

| Variable      | Was beim Start passiert                                  |
| ------------- | -------------------------------------------------------- |
| `SHARE_ALL=1` | Skills → sbx-Store; alle installierten Plugins aktiviert |
| `MCP_SERVERS` | `sbx mcp load <name> --sandbox devbox-alles` je Eintrag  |
| `MCP_CONFIG`  | `mcpServers` der Datei → `~/.claude.json` der Sandbox    |

Für die Plugins entsteht dabei eine `~/.claude/settings.json` **in** der Sandbox,
die jedes Plugin aus `installed_plugins.json` einschaltet. Alles davon ist
idempotent — jedes `up` zieht es neu nach.

> ⚠️ **Was du dabei aufgibst.** Der Skill-Store von `sbx` ist read-write und
> wird von **allen** Sandboxes dieser Maschine geteilt, auch von fremden. Auf
> deinem eigenen Rechner ist das die gewünschte Bequemlichkeit; auf einem
> geteilten Rechner ist es ein Seitenkanal zwischen Sandboxes. Deshalb ist
> `SHARE_ALL` standardmäßig **aus**.

Zwei Dinge bleiben auch mit `SHARE_ALL` so, wie sie sind:

- **Die `settings.json` des Hosts wird weiter nicht gemountet.** Die Datei in
  der Sandbox wird erzeugt und enthält nur `enabledPlugins` — Host-Berechtigungen
  wandern nicht in den Container.
- **Kopie, kein Mount.** Ein neuer Skill oder ein neues Plugin auf dem Host ist
  erst nach dem nächsten `up` in der Sandbox. Plugin-_Inhalte_ sind weiterhin
  live gemountet, nur ihre Aktivierungsliste wird beim Start geschrieben.

Die lange Fassung mit den Begründungen:
[Kapitel 6](tutorial/06-globale-und-lokale-config.md).

---

## Wenn sich dieses Repo geändert hat

Nach einem `git pull` im devbox-Repo:

```bash
cd ~/dev/own/devbox && git pull
./devbox/devbox.sh status        # sagt dir, ob mehr zu tun ist
```

| Was sich geändert hat        | Was zu tun ist                                                                                                                                                       |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/`, `README.md`         | nichts                                                                                                                                                               |
| `devbox/devbox.sh`           | nichts — der Alias zeigt auf die Datei, der nächste Aufruf nimmt die neue Version                                                                                    |
| `devbox/Dockerfile`          | **Template neu bauen** — siehe unten                                                                                                                                 |
| `devbox/devbox.conf.example` | deine `~/.config/devbox/devbox.conf` ist eine **Kopie** und wird nicht mitgezogen. Vergleiche selbst: `diff devbox/devbox.conf.example ~/.config/devbox/devbox.conf` |

### Template geändert (neues Dockerfile)

`status` und `doctor` melden dann _„Dockerfile hat sich geändert"_.

```bash
./devbox/devbox.sh update        # baut neu UND nennt die veralteten Sandboxes
./devbox/devbox.sh rm privat     # nur für die betroffenen
./devbox/devbox.sh up privat     # holt das neue Template
```

Warum drei Schritte: Eine Sandbox wird beim **Anlegen** aus dem Template kopiert
und danach nie wieder daran angeglichen. `update` allein ändert an einer
bestehenden Sandbox nichts.

Der `rm`-Schritt kostet den Claude-Login und zur Laufzeit installierte Pakete.
Deine Projektdateien liegen auf dem Host und bleiben unberührt. Brauchst du das
Neue nicht sofort, kannst du `rm`/`up` aufschieben — `status` erinnert dich.

---

## Die Wrapper-Kommandos

| Kommando                            | Was passiert                                                  | Ersetzt von Hand                                        |
| ----------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------- |
| `./devbox.sh doctor`                | prüft Werkzeuge, Template-Stand, Config auf dem **Host**      | —                                                       |
| `./devbox.sh status`                | zeigt, **was läuft**: Template, unsere Sandboxes, deren Stand | `sbx ls` + `sbx template ls`                            |
| `./devbox.sh build`                 | Image bauen → tar → Template laden                            | `docker build` + `docker save` + `sbx template load`    |
| `./devbox.sh build --force`         | dasselbe, auch bei unverändertem Dockerfile                   | —                                                       |
| `./devbox.sh update`                | neu bauen **und** sagen, welche Sandboxes noch alt sind       | `build --force` + Abgleich                              |
| `./devbox.sh up [profil]`           | Sandbox anlegen + Netzregeln + Symlinks + Claude starten      | `sbx create` + `sbx policy` + `sbx exec -d` + `sbx run` |
| `./devbox.sh shell [profil]`        | bash in der laufenden Sandbox                                 | `sbx exec -it <name> bash`                              |
| `./devbox.sh allow <host> [profil]` | einen Host freigeben (nur diese Sandbox)                      | `sbx policy allow network --sandbox <name> <host>`      |
| `./devbox.sh rm [profil]`           | Sandbox entfernen, fragt vorher nach                          | `sbx rm --force <name>`                                 |

Ohne Profilangabe gilt immer `privat`. Setzt das Profil `SHARE_ALL` oder
`MCP_SERVERS`/`MCP_CONFIG`, erledigt `up` zusätzlich Skills, Plugins und
MCP-Server — siehe [Alles sofort dabei](#alles-sofort-dabei-share_all).

**`doctor` oder `status`?** `doctor` fragt „ist mein Host richtig eingerichtet?",
`status` fragt „was läuft gerade?".

**Merke:** `build` ist pro _Maschine_, `up` ist pro _Profil_. Ein Template
bedient beliebig viele Sandboxes.

Dockerfile geändert? Der Ablauf steht oben unter
[Template geändert](#template-geändert-neues-dockerfile).

---

## Die rohen `sbx`-Kommandos

Falls der Wrapper klemmt — hiermit kommst du immer weiter:

```bash
sbx version                              # Version prüfen (v0.38+)
sbx login                                # ohne Anmeldung tut sbx nichts
sbx diagnose                             # sbx prüft seine eigene Installation
sbx ls                                   # welche Sandboxes existieren
sbx ls -q                                # nur die Namen
sbx ls --json                            # maschinenlesbar
sbx template ls                          # welche Templates liegen im Store

sbx create -t devbox/base:latest --name devbox-privat claude ~/dev/own
sbx run  --name devbox-privat claude     # Claude in der Sandbox starten
sbx exec -it devbox-privat bash          # Shell hinein
sbx exec -d  devbox-privat bash -c '…'   # Kommando im Hintergrund
sbx cp datei.txt devbox-privat:/tmp/     # Dateien rein und raus
sbx stop devbox-privat                   # anhalten, OHNE den Zustand zu verlieren
sbx rm --force devbox-privat             # weg damit — Login ist dann weg

sbx policy ls devbox-privat              # geltende Regeln ansehen
sbx policy ls devbox-privat --wide       # bis auf Regelebene
sbx policy allow network --sandbox devbox-privat '*.example.com'
```

`sbx stop` gegen `sbx rm`: **stop** hält den Container an und behält alles —
Login, installierte Pakete, Änderungen. **rm** wirft ihn weg.

> ⚠️ **Immer `--sandbox` bei `policy allow`.** Ohne das Flag gilt die Regel
> **global**, also für jede Sandbox auf diesem Rechner — auch für die, die dir
> nicht gehören.

---

## Netz

Standardmäßig darf die Sandbox **nur** die Hosts aus `BASE_HOSTS` in
[devbox.sh](../devbox/devbox.sh#L65-L75): Anthropic, GitHub, npm, PyPI, astral,
Aikido. Alles andere schlägt fehl — das ist der Normalfall, kein Defekt.

```bash
./devbox/devbox.sh allow '*.googleapis.com' privat    # für jetzt
```

Damit es den nächsten Neustart überlebt, den Host als `EXTRA_HOSTS` ins Profil
eintragen:

```bash
$EDITOR ~/.config/devbox/devbox.conf
```

---

## Profile

Liegen in `~/.config/devbox/devbox.conf`, bewusst außerhalb des Repos. Vorlage:
[devbox.conf.example](../devbox/devbox.conf.example).

```bash
privat)
  NAME="privat"                      # -> Sandbox "devbox-privat"
  WORKSPACES=( "$HOME/dev/own" )     # Dach-Ordner; der ERSTE ist der Startordner
  EXTRA_HOSTS=()
  ;;
```

Drei optionale Variablen kommen dazu, alle standardmäßig aus: `SHARE_ALL`,
`MCP_SERVERS`, `MCP_CONFIG` — siehe
[Alles sofort dabei](#alles-sofort-dabei-share_all).

> ⚠️ **Workspaces gehen nur beim Anlegen.** Ein Ordner, der beim `sbx create`
> fehlte, lässt sich später nicht nachrüsten — nur über `rm` und neu anlegen
> (und damit neuen Login). Deshalb: **Dach-Ordner mounten, keine
> Einzelprojekte.**

Mehrere Profile laufen gleichzeitig und unabhängig — eigener Zustand, eigene
Netzregeln, eigener Login:

```bash
./devbox/devbox.sh up privat
./devbox/devbox.sh up lernen
```

---

## Was `rm` kostet

| Bleibt                                     | Ist weg                                    |
| ------------------------------------------ | ------------------------------------------ |
| deine Projektdateien (liegen auf dem Host) | der Claude-Login                           |
| das Template (`build` nicht nötig)         | zur Laufzeit installierte Pakete           |
| deine `~/.claude`-Ordner auf dem Host      | Änderungen an `/etc/sandbox-persistent.sh` |

Deshalb ist `rm` nicht Teil der täglichen Routine, sondern die Notbremse.

---

## In der Sandbox

```bash
python --version                 # 3.12 (Standard)
uv python list                   # 3.10 / 3.12 / 3.14 stehen bereit
pnpm --version                   # darf KEINE Corepack-Download-Meldung zeigen

export DEVBOX_SAFE_CHAIN=0       # Malware-Scan beim Installieren abschalten
```

Dauerhaft — überlebt Neustarts der Sandbox, nicht aber `rm`:

```bash
echo 'export DEVBOX_SAFE_CHAIN=0' >> /etc/sandbox-persistent.sh
```

Prüfen, ob die globale Config angekommen ist:

```bash
sbx exec -it devbox-privat bash -c 'ls -la ~/.claude'
```

Erwartet: Symlinks für `agents`, `commands`, `rules`, `plugins`. **`skills` ist
absichtlich kein Symlink** — dort hängt `sbx` seinen eigenen, maschinenweit
geteilten Store ein. Siehe [architektur.md](architektur.md).

---

## Wenn etwas klemmt

Der Reihe nach:

```bash
./devbox/devbox.sh doctor        # 1. ist der Host eingerichtet?
./devbox/devbox.sh status        # 2. was läuft, auf welchem Template?
sbx diagnose                     # 3. ist sbx selbst gesund?
sbx policy ls devbox-privat      # 4. hängt es am Netz?
./devbox/devbox.sh shell privat  # 5. selbst nachsehen
```

Zeigt `status` „kein Template im sbx-Store", ist die zweite Ursache mindestens so
wahrscheinlich wie die erste: **du bist nicht angemeldet.** `sbx template ls`
antwortet dann mit _ERROR: Not authenticated to Docker_ — ein `sbx login` hilft.

Die häufigen Fehler in der Reihenfolge, in der sie auftreten:
[troubleshooting.md](troubleshooting.md).

---

## Einen Alias anlegen

Ziel: statt `~/dev/own/devbox/devbox/devbox.sh up privat` nur noch
`devbox up privat` — aus **jedem** Verzeichnis.

Das Skript findet sein Dockerfile selbst (über `BASH_SOURCE`), es ist also
egal, wo du stehst.

### macOS

Standard-Shell ist seit Catalina **zsh**:

```bash
echo 'alias devbox="$HOME/dev/own/devbox/devbox/devbox.sh"' >> ~/.zshrc
source ~/.zshrc
```

Benutzt du bash (`echo $SHELL` sagt `/bin/bash`), dann in `~/.bash_profile`
statt `~/.zshrc` — auf macOS liest die Login-Shell `~/.bashrc` **nicht**
automatisch.

### Linux

```bash
echo 'alias devbox="$HOME/dev/own/devbox/devbox/devbox.sh"' >> ~/.bashrc
source ~/.bashrc
```

Bei zsh (Arch, Manjaro, oft auch Fedora-Setups) entsprechend `~/.zshrc`.

### Windows

`devbox.sh` ist ein Bash-Skript — Windows braucht also eine Bash. Die
Einrichtung steht in [Kapitel 0](tutorial/00-vorbereitung.md#windows); hier nur
der Alias selbst. Zwei Wege:

**① WSL2 — der empfohlene Weg.** Docker Desktop mit WSL2-Backend, alles andere
läuft dann genau wie unter Linux:

```bash
# in der WSL-Distribution
echo 'alias devbox="$HOME/dev/own/devbox/devbox/devbox.sh"' >> ~/.bashrc
source ~/.bashrc
```

> Lege das Repo **innerhalb** des WSL-Dateisystems ab (`~/dev/…`), nicht unter
> `/mnt/c/…`. Über die Windows-Grenze ist der Dateizugriff um Größenordnungen
> langsamer, und das merkt man bei einem Image von ~6 GB deutlich.

**② PowerShell als Vorderseite.** Wenn du in PowerShell arbeitest, aber das
Skript in WSL läuft, hilft eine Funktion — ein PowerShell-`alias` kann keine
Argumente weiterreichen, eine Funktion schon:

```powershell
notepad $PROFILE          # legt die Datei bei Bedarf an
```

```powershell
function devbox {
    wsl ~/dev/own/devbox/devbox/devbox.sh @args
}
```

Dann `. $PROFILE` oder neues Fenster.

> **Git Bash** funktioniert für einfache Fälle, ist aber nicht die getestete
> Umgebung: Pfade werden in MSYS-Form umgeschrieben (`/c/Users/…`), was bei den
> Mount-Pfaden von `sbx create` zu Überraschungen führt. Wenn möglich: WSL2.

### Statt Alias: eine Funktion

Ein Alias reicht, weil bash und zsh die Argumente anhängen. Eine Funktion kann
mehr — zum Beispiel ein Standardprofil setzen:

```bash
# in ~/.zshrc bzw. ~/.bashrc
devbox() {
  local skript="$HOME/dev/own/devbox/devbox/devbox.sh"
  # Ohne Argumente: direkt das Alltagskommando statt der Hilfe.
  if [ $# -eq 0 ]; then
    "$skript" up privat
  else
    "$skript" "$@"
  fi
}
```

### Oder: ins PATH legen

Wer keine Shell-Datei anfassen will, verlinkt das Skript in einen Ordner, der
schon im `PATH` steht:

```bash
mkdir -p ~/.local/bin
ln -sfn ~/dev/own/devbox/devbox/devbox.sh ~/.local/bin/devbox
```

`~/.local/bin` ist auf den meisten Linux-Distributionen bereits im `PATH`, auf
macOS meist nicht — dort dann einmalig:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

---

## Die sechs Merksätze

1. **Workspaces nur beim Anlegen.** Dach-Ordner mounten, nicht Einzelprojekte.
2. **`policy allow` immer mit `--sandbox`.** Sonst triffst du fremde Sandboxes.
3. **`build` pro Maschine, `up` pro Profil.**
4. **Ein neues Template erreicht alte Sandboxes nicht.** `update` sagt dir, wen.
5. **Ein blockierter Host ist der Normalfall,** kein Fehler.
6. **`rm` kostet den Login.** Erst `status` und `shell`, dann `rm`.

---

## Wenn du am Repo selbst arbeitest

Dasselbe, was die CI prüft — läuft auch lokal:

```bash
shellcheck devbox/devbox.sh scripts/check-links.sh
bash -n devbox/devbox.conf.example
./scripts/check-links.sh
```

Nach Änderungen am Dockerfile zusätzlich:

```bash
./devbox/devbox.sh update
docker run --rm devbox/base:latest bash -lc 'python --version; pnpm --version'
```
