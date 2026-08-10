# Fehlersuche

Die Probleme in der Reihenfolge, in der sie erfahrungsgemäß auftreten.

Der größte Teil gilt für **beide Varianten** — die Fehler stecken in `sbx`, nicht
im Wrapper. Was nur `solobox` betrifft, steht gesammelt am
[Ende dieser Seite](#nur-solobox-variante-2).

---

## Windows: `./devbox/devbox.sh` wird nicht erkannt

```bash
./devbox/devbox.sh : The term './devbox/devbox.sh' is not recognized as the name
of a cmdlet, function, script file, or operable program.
```

`devbox.sh` ist ein Bash-Skript, PowerShell kann es nicht ausführen. Nutze
**WSL2** — Einrichtung in [Kapitel 0](tutorial/00-vorbereitung.md#windows).

Läuft es in WSL, ist aber quälend langsam: Liegt das Repo unter `/mnt/c/...`?
Dann in das WSL-Dateisystem verschieben (`~/dev/own/devbox`). Der Zugriff über
die Windows-Grenze ist um Größenordnungen langsamer.

Antwortet `docker` in WSL nicht, fehlt in Docker Desktop die WSL-Integration:
_Settings → Resources → WSL integration_ für die Distribution einschalten.

---

## `sbx` meldet „Not authenticated to Docker"

```bash
ERROR: Not authenticated to Docker
Sign in with: sbx login
```

```bash
sbx login
```

Kommt die Meldung zusammen mit Zeilen wie
`open .../com.docker.sandboxes/.../settings.json.lock: operation not permitted`,
liegt es **nicht** an der Anmeldung, sondern daran, dass der Prozess nicht auf
das Zustandsverzeichnis von `sbx` zugreifen darf. Das passiert zum Beispiel,
wenn `sbx` selbst aus einer eingeschränkten Umgebung heraus aufgerufen wird.
Führe die `sbx`-Befehle dann direkt in einem normalen Terminal aus.

**Wie sich das im Wrapper zeigt:** `./devbox.sh status` meldet dann
_„kein Template im sbx-Store"_. Das ist dieselbe Ursache — ohne Anmeldung kann
`sbx template ls` den Store nicht lesen, und von außen sieht „nicht angemeldet"
genauso aus wie „nichts gebaut".

---

## „global network policy has not been initialized"

Einmaliger Schritt pro Rechner:

```bash
sbx policy init balanced
```

---

## `sbx create` bricht ab, weil ein Ordner fehlt

Alle Pfade in `WORKSPACES` und alle gemounteten `~/.claude`-Unterordner müssen
existieren, bevor die Sandbox angelegt wird.

```bash
for d in agents skills commands rules plugins; do mkdir -p ~/.claude/$d; done
```

`./devbox.sh up` erledigt das automatisch.

---

## „...can't be given new workspaces"

Du versuchst, einer **bestehenden** Sandbox einen Ordner nachzureichen. Das geht
nicht — Workspaces sind nur beim Anlegen setzbar (siehe
[Kapitel 5](tutorial/05-mehrere-projekte.md)).

Entweder du kommst ohne den Ordner aus, oder:

```bash
./devbox.sh rm privat      # ⚠️ Login und Laufzeitzustand gehen verloren
./devbox.sh up privat
```

Damit das nicht wieder passiert: einen **Dach-Ordner** mounten.

---

## pnpm lädt beim ersten Aufruf eine andere Version nach

```bash
$ pnpm --version
! Corepack is about to download .../pnpm-11.21.0.tgz
11.21.0
```

Dann kommt `pnpm` aus corepack statt aus unserer festen Installation.

Ursache: `corepack prepare --activate` legt seine Aktivierung im Cache des
**Bau-Users** (`root`) ab. Zur Laufzeit läuft aber `agent` — der sieht davon
nichts und fällt auf „neueste Version" zurück.

Lösung (steht so im Dockerfile): pnpm als normales globales npm-Paket
installieren, nicht über corepack.

```dockerfile
RUN npm install -g pnpm@10.11.0
```

Prüfen:

```bash
docker run --rm devbox/base:latest bash -lc 'pnpm --version'
# 10.11.0, ohne Download-Meldung
```

---

## „Safe-chain: User defined SSL_CERT_FILE found … It will be overwritten"

Kein Fehler. Safe Chain arbeitet als lokaler Proxy und muss dafür die
TLS-Zertifikate umbiegen — die Meldung erscheint bei jedem `uv`- oder
`npm`-Aufruf. Wenn sie stört:

```bash
DEVBOX_SAFE_CHAIN=0 uv sync
```

---

## `npm install safe-chain-test` wird nicht blockiert

Der Schutz ist nicht aktiv. Prüfen, ob das Shim-Verzeichnis vorne im PATH steht:

```bash
echo "$PATH" | tr ':' '\n' | head -3
# /opt/safe-chain/shims sollte dabei sein
command -v npm
# sollte /opt/safe-chain/shims/npm zeigen
```

Fehlt es, ist entweder `DEVBOX_SAFE_CHAIN=0` gesetzt:

```bash
echo "$DEVBOX_SAFE_CHAIN"
```

…oder `/etc/sandbox-persistent.sh` wurde nicht gesourct. Das passiert bei
`sbx exec` ohne `bash -c`:

```bash
sbx exec devbox-privat bash -c "npm --version"    # richtig
sbx exec devbox-privat npm --version              # PATH nicht gesetzt
```

---

## Ein Netzwerkaufruf schlägt fehl

Das ist der Normalfall bei einer kurzen Erlaubnisliste, kein Defekt.

```bash
sbx policy ls devbox-privat              # was ist erlaubt?
./devbox.sh allow '*.example.com'        # freigeben
```

Damit es dauerhaft gilt, trage den Host als `EXTRA_HOSTS` in
`~/.config/devbox/devbox.conf` ein.

---

## Globale Skills und Agents tauchen nicht auf

Prüfe die Symlinks:

```bash
sbx exec -it devbox-privat bash -c 'ls -la ~/.claude'
```

Erwartung: Symlinks, die auf die gemounteten Host-Pfade zeigen. Fehlen sie:

```bash
./devbox.sh up privat     # setzt sie bei jedem Start neu
```

Zeigen die Symlinks ins Leere, wurde der Ordner beim Anlegen nicht gemountet —
dann hilft nur `rm` + `up`.

---

## Globale Skills fehlen, obwohl `agents` und `commands` da sind

Das ist so gewollt. `sbx` hängt an `/home/agent/.claude/skills` seinen **eigenen**
Skill-Store ein — denselben für alle Sandboxes der Maschine. Ein Symlink dorthin
schlägt nicht fehl, sondern landet still _im_ Store und wäre damit in jeder
anderen Sandbox sichtbar. Deshalb überspringt der Wrapper `skills` bewusst
(Details in [architektur.md](architektur.md#der-sonderfall-skills)).

Deine globalen Skills sind trotzdem **lesbar**, nur eben unter dem Host-Pfad:

```bash
sbx exec devbox-privat bash -c 'ls /Users/DEINNAME/.claude/skills'
```

Brauchst du einen davon, kopiere ihn nach `.claude/skills/` des Projekts — dort
wird er zuverlässig gefunden und ist nebenbei versioniert.

Wer den geteilten Store bewusst nutzen will, setzt `SHARE_ALL=1` im Profil —
dann kopiert jedes `up` die globalen Skills selbst dorthin:

```bash
$EDITOR ~/.config/devbox/devbox.conf     # SHARE_ALL=1 im gewünschten Profil
./devbox/devbox.sh up privat
```

Von Hand ginge auch `sbx skills import`.

⚠️ Beides wirkt auf **alle** Sandboxes des Rechners, nicht nur auf devbox. Die
Abwägung steht in
[Kapitel 6](tutorial/06-globale-und-lokale-config.md#alles-auf-einmal--und-was-es-kostet).

---

## Plugins werden nicht geladen, obwohl der Ordner da ist

Der Ordner bringt die Registrierung mit (`installed_plugins.json`), aber nicht
die _Aktivierung_ — die steht in `settings.json`, die wir bewusst nicht mounten.

Aktiviere das Plugin projektlokal:

```json
// <projekt>/.claude/settings.json
{
	"enabledPlugins": {
		"mattpocock-skills@claude-plugins-official": true
	}
}
```

Sollen alle installierten Plugins in jedem Projekt der Sandbox gelten, nimm
stattdessen `SHARE_ALL=1` im Profil — dann erzeugt jedes `up` diese Liste selbst,
in `~/.claude/settings.json` der Sandbox.

Der Inhalt eines Plugins ist übrigens live gemountet, nur read-only: `/plugin
update` scheitert deshalb in der Sandbox. Aktualisiere auf dem Host, die neue
Version ist sofort drin.

---

## MCP-Server fehlt in der Sandbox

Prüfe in der Claude-Session mit `/mcp`, was überhaupt verbunden ist. Dann der
Reihe nach:

| Symptom                        | Ursache und Abhilfe                                              |
| ------------------------------ | ---------------------------------------------------------------- |
| Server taucht gar nicht auf    | nicht registriert: `.mcp.json`, `MCP_CONFIG` oder `sbx mcp load` |
| Server startet, liefert nichts | Ziel-Host fehlt in der Policy: `./devbox.sh allow <host>`        |
| `sbx mcp load` schlägt fehl    | erst `sbx mcp add …`, dann `sbx mcp ls` prüfen                   |
| Server aus einem Plugin fehlt  | Plugin nicht aktiviert — siehe den Abschnitt darüber             |

---

## Playwright startet keinen Browser

Dem Basis-Image fehlt eine Systembibliothek. `playwright install-deps` darf im
Dockerfile bewusst weich fehlschlagen (`|| true`), weil es für sehr neue
Ubuntu-Versionen nicht immer eine gepflegte Paketliste gibt.

Fehlende Bibliothek ermitteln und in Schritt 1 des Dockerfiles ergänzen:

```bash
sbx exec -it devbox-privat bash -c 'ldd /ms-playwright/chromium-*/chrome-linux/chrome | grep "not found"'
```

---

## Ein neues Werkzeug fehlt, obwohl das Image neu gebaut ist

Du hast das Dockerfile ergänzt, `build` lief durch — und in der Sandbox ist das
Werkzeug trotzdem nicht da.

Erwartet. Eine Sandbox wird beim **Anlegen** aus dem Template kopiert und danach
nie wieder daran angeglichen. Ein neues Template erreicht sie nicht.

```bash
./devbox/devbox.sh update        # baut neu und nennt die veralteten Sandboxes
./devbox/devbox.sh rm privat     # nur für die betroffene
./devbox/devbox.sh up privat     # holt das neue Template
```

Der Preis dafür steht im nächsten Abschnitt. Wer ihn vermeiden will, installiert
das Werkzeug einmalig direkt in der laufenden Sandbox
(`./devbox.sh shell privat`) — das überlebt aber kein `rm`, ist also die
Notlösung, nicht der Weg.

---

## Nach einem `rm` ist der Login weg

Erwartet. `sbx rm` löscht den Zustand **in** der Sandbox:

- den Claude-Login
- zur Laufzeit installierte Pakete
- Änderungen an `/etc/sandbox-persistent.sh`

Nicht betroffen sind deine Projektdateien — die liegen auf dem Host.

Was dauerhaft überleben soll, gehört ins **Dockerfile**, nicht in die laufende
Sandbox.

---

## Der Build dauert ewig / die Platte läuft voll

Das Image belegt rund 5,9 GB, die tar-Datei beim Übertragen etwa 1,4 GB
(`docker save` komprimiert).

- `./devbox.sh build` überspringt den Vorgang, solange sich das Dockerfile nicht
  geändert hat. `./devbox.sh update` baut dagegen immer (`--force`).
- Aufräumen: `docker image prune` und alte `devbox/base`-Versionen entfernen.
- Wer Playwright nicht braucht: Schritt 7 aus dem Dockerfile entfernen, das
  spart mehrere GB.

---

## Nur solobox (Variante 2)

## `solobox: command not found`

Der Symlink fehlt oder liegt nicht auf dem `PATH`:

```bash
chmod +x solobox/solobox.sh
./solobox/solobox.sh install
solobox doctor
```

`install` sagt dir, wenn `~/.local/bin` nicht auf dem `PATH` liegt.

## `permission denied` beim Aufruf

Dem Skript fehlt das Ausführbar-Bit — bei frisch geschriebenen Dateien der
Normalfall:

```bash
chmod +x solobox/solobox.sh
```

Genau das prüft die CI mit `test -x`, damit es niemandem sonst passiert.

## `workspace path exists but is not a directory`

```bash
ERROR: workspace path exists but is not a directory: /Users/du/.gitconfig
```

`sbx` hängt als Workspace **nur Verzeichnisse** ein. Steht in `ROOTS` eine
einzelne Datei, bricht das Anlegen ab. Seit dieser Fassung prüft der Wrapper das
vorher und sagt es deutlicher — `solobox doctor` zeigt es ebenfalls an.

Eine einzelne Datei bringst du mit `sbx cp` hinein. Für die **Git-Identität**
brauchst du das nicht: solobox liest `user.name` und `user.email` vom Host und
setzt sie bei jedem `up` in der Sandbox (`apply_git_identity`). Das ist auch der
bessere Weg — eine echte `~/.gitconfig` enthält oft `includeIf`-Blöcke und
Credential-Helfer-Pfade, die im Container ins Leere zeigen.

## Commits aus der Sandbox haben keinen Autor

```bash
Author identity unknown
```

Auf dem Host ist keine globale Identität gesetzt, also kann solobox auch keine
übernehmen:

```bash
git config --global user.name  "Dein Name"
git config --global user.email "du@example.com"
solobox sync
```

## Der projektlokale Skill / die `CLAUDE.md` wird ignoriert

Fast immer wurde Claude **nicht im Projektordner gestartet**. Claude Code liest
`CLAUDE.md`, `.claude/` und `.mcp.json` beim **Start** aus dem
Arbeitsverzeichnis; ein `cd` in der laufenden Sitzung holt das nicht nach.

```bash
/status          # zeigt das Arbeitsverzeichnis
```

Steht dort die Wurzel (`~/dev`) statt deines Projekts, dann beenden und neu:

```bash
cd ~/dev/own/mein-projekt
solobox up
```

## „liegt unter keiner der Wurzeln"

```bash
!! '/Users/du/woanders' liegt unter keiner der Wurzeln (/Users/du/dev ...)
```

Die Sandbox sieht diesen Ordner nicht. Workspaces stehen beim Anlegen fest — der
Ordner lässt sich **nicht** nachreichen. Entweder das Projekt unter eine
bestehende Wurzel verschieben, oder:

```bash
$EDITOR ~/.config/solobox/solobox.conf     # ROOTS ergänzen
solobox rm && solobox up                   # kostet den Login
```

## Nach jeder Antwort erscheint ein Hook-Fehler

```bash
osascript: command not found
```

Ein Hook aus deiner globalen `settings.json` ruft Host-Werkzeuge auf, die es im
Container nicht gibt (`osascript`, `terminal-notifier`, `open`, `pbcopy`). Diese
Hooks gehören in `HOOK_SKIP`:

```bash
HOOK_SKIP=(Notification Stop)   # Standard
```

`solobox sync` schreibt die Datei danach neu. Alternativ den Hook auf dem Host
verträglich machen — die Zeile dafür steht in
[Tutorial-Kapitel 3](tutorial-solo/03-hooks-plugins-settings.md).

## Ein neuer Skill vom Host fehlt in der Sandbox

Skills werden **kopiert**, nicht gemountet (sonst würde der Link im geteilten
sbx-Store landen). Nachziehen:

```bash
solobox sync
```

Die laufende Claude-Sitzung sieht ihn nach einem Neustart der Sitzung.

Für Agents, Commands, Rules und Plugins gilt das **nicht** — die sind gemountet
und sofort aktuell.

## Andere Sandboxes sehen plötzlich meine globalen Skills

Kein Fehler, sondern der Standard: `/home/agent/.claude/skills` ist der
Skill-Store von `sbx`, den sich alle Sandboxes der Maschine teilen.

```bash
solobox status     # zeigt, wer sich den Store mit dir teilt
```

Wenn das nicht gewollt ist:

```bash
ISOLATE_SKILLS=1   # in ~/.config/solobox/solobox.conf
solobox rm && solobox up
```

`solobox doctor` prüft vorher, ob deine `sbx`-Version das dafür nötige
(undokumentierte) `--no-share-skills` überhaupt kennt.

## Claude fragt vor einem Bash-Befehl nicht nach

Erwartet, und zwar aus bis zu drei Gründen — in dieser Reihenfolge prüfen:

**1. Läuft die Sitzung mit abgeschalteten Berechtigungen?**

```bash
sbx exec solobox bash -lc 'ps -eo pid,etime,args | grep [c]laude'
```

Steht dort `claude --dangerously-skip-permissions`, wurde sie über `sbx run`
gestartet — das tut `solobox up` nur beim allerersten Mal nach dem Anlegen.
`/exit`, dann `solobox up` erneut; die neue Sitzung läuft ohne das Flag.

**2. Der Befehl lief in Claudes eigenem Sandkasten.**
Claude Code sandboxt Bash-Aufrufe in der Sandbox selbst und lässt sie dann ohne
Rückfrage zu (`autoAllowBashIfSandboxed`). Das ist der Normalfall und kein
Fehler.

**3. Die eigentliche Grenze ist das Arbeitsverzeichnis.**
Schreibversuche außerhalb des Ordners, in dem Claude gestartet wurde, werden
hart abgewiesen:

```bash
Schreibzugriff außerhalb des erlaubten Arbeitsverzeichnisses blockiert
```

Wer echte Rückfragen will, nimmt `"sandbox": {"autoAllowBashIfSandboxed": false}`
in die abgeleitete `settings.json` auf. Wer weniger Radius will, startet
`solobox up` im Projekt statt in `~/dev` — das wirkt stärker als jede
Einstellung.

## solobox: `npm install safe-chain-test` wird nicht blockiert

Der Schutz ist nicht aktiv. Prüfen, ob das Shim-Verzeichnis vorne im `PATH`
steht:

```bash
sbx exec solobox bash -lc 'echo "$PATH" | tr ":" "\n" | head -3'
# /opt/safe-chain/shims sollte dabei sein
sbx exec solobox bash -lc 'command -v npm; type -t npm'
# /opt/safe-chain/shims/npm   und   file
```

Sagt `type -t npm` etwas anderes als `file`, wurde `/etc/sandbox-persistent.sh`
nicht gelesen — das passiert bei `sbx exec` **ohne** Shell:

```bash
sbx exec solobox bash -lc 'npm install foo'   # richtig
sbx exec solobox npm install foo              # PATH nicht gesetzt
```

Oder der Schalter steht auf aus:

```bash
sbx exec solobox bash -lc 'echo "${SOLOBOX_SAFE_CHAIN:-1}"'
```

Scharftest:

```bash
sbx exec solobox bash -lc 'cd /tmp && mkdir -p sc && cd sc && npm init -y >/dev/null && npm install safe-chain-test'
# ✖ Safe-chain: Malicious changes detected
```

> **Historie:** Bis zur Shim-Fassung war der Schutz hier eine Shell-Funktion.
> Die ließ sich mit `timeout npm install …`, `env npm install …` oder `xargs`
> aushebeln, weil eine Funktion kein Programm ist. Falls du ein älteres Image
> benutzt (`type -t npm` sagt `function`), baue neu: `solobox update`, danach
> `solobox rm && solobox up`.

## `/plugin` kann in der Sandbox nichts installieren

Erwartet. `~/.claude/plugins` ist **read-only** eingehängt. Plugins installierst
du auf dem Host; danach holt `solobox sync` sie in die laufende Sandbox.

## `syntax error near unexpected token '<'`

```text
oliverjung@Mac solobox % sh solobox.sh install
solobox.sh: line 488: syntax error near unexpected token `<'
```

Nicht das Skript ist kaputt, sondern die Shell davor. `sh solobox.sh` **ignoriert
die Shebang-Zeile**, und `/bin/sh` ist auf macOS eine Bash 3.2 im POSIX-Modus —
die kennt keine Prozess-Substitution (`done < <(…)`). Der Fehler zeigt deshalb
auf eine Zeile weit hinten im Skript, obwohl der Startbefehl das Problem ist.

Richtig ist:

```bash
./solobox.sh install       # nutzt die Shebang-Zeile
bash solobox.sh install    # oder bash ausdrücklich
```

Seit dieser Fassung startet sich `solobox.sh` in dem Fall selbst unter bash neu
und sagt es dazu — `sh solobox.sh` funktioniert also auch. Die Erkennung ist
zweistufig, weil `BASH_VERSION` unter `sh` **gesetzt** ist (es *ist* bash); der
POSIX-Modus verrät sich nur über `shopt -qo posix`.

Fehlt bash ganz, bricht das Skript mit einem klaren Satz ab.

## `shasum: /Users/du/.local/bin/Dockerfile: No such file or directory`

```text
oliverjung@Mac projekt % solobox up
shasum: /Users/oliverjung/.local/bin/Dockerfile: No such file or directory
```

Das Skript sucht sein Dockerfile im Ordner, in dem es zu liegen glaubt — und
über den Symlink in `~/.local/bin` war das der falsche. Behoben: `solobox.sh`
löst Symlinks jetzt auf, bevor es sein Verzeichnis bestimmt, und meldet ein
fehlendes Dockerfile mit einem verständlichen Satz statt mit einer
`shasum`-Fehlermeldung.

Tritt es weiterhin auf, zeigt der Symlink ins Leere — typisch, wenn das Repo
verschoben wurde:

```bash
ls -l ~/.local/bin/solobox        # wohin zeigt er?
cd <pfad-zum-repo> && ./solobox/solobox.sh install
solobox doctor
```

## `solobox check` sagt, die Sandbox müsse neu angelegt werden

Zwei Ursachen führen zu Stufe 3, und `check` nennt immer die konkrete:

**„Sandbox läuft auf einem ÄLTEREN Image"** — das Dockerfile wurde geändert und
neu gebaut, aber ein neues Template erreicht eine bestehende Sandbox nicht.
Container werden beim Anlegen aus dem Template kopiert, nicht laufend
angeglichen.

**„Sandbox passt nicht zur Konfiguration"** — `ROOTS` oder `CLAUDE_SHARED`
enthalten einen Pfad, den die Sandbox nicht eingehängt hat (oder umgekehrt).
Workspaces sind nur beim Anlegen setzbar; `check` zeigt, welcher Pfad fehlt.

Beides kostet beim Beheben den Claude-Login:

```bash
solobox rm && solobox up
```

Willst du es nicht: `solobox up` startet auf Nachfrage auch die alte Sandbox
weiter — die Änderung gilt dort dann eben nicht.

## `solobox check` sagt „Image trägt keinen Stempel"

Das Image wurde mit einer solobox-Version vor der Stempel-Einführung gebaut.
Harmlos, aber die Ebenen 1 und 3 können dann nichts prüfen:

```bash
solobox build --force
```

Danach trägt das Image sein Label und `/etc/solobox-stamp`.

## `solobox check` meldet „kein Template im Store", obwohl gebaut wurde

Fast immer fehlt die Docker-Anmeldung — `sbx template ls` endet dann mit
`ERROR: Not authenticated to Docker`, und von außen sieht das genauso aus wie
„nichts gebaut":

```bash
sbx login
solobox check
```

Kommen dabei Zeilen wie
`open .../com.docker.sandboxes/.../settings.json.lock: operation not permitted`,
darf der aufrufende Prozess nicht auf das Zustandsverzeichnis von `sbx` zugreifen
— dann `solobox` aus einem normalen Terminal starten.
