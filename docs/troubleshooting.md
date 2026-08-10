# Fehlersuche

Die Probleme in der Reihenfolge, in der sie erfahrungsgemäß auftreten.

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
