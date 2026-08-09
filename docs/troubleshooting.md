# Fehlersuche

Die Probleme in der Reihenfolge, in der sie erfahrungsgemäß auftreten.

---

## `sbx` meldet „Not authenticated to Docker"

```
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

```
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
schlägt nicht fehl, sondern landet still *im* Store und wäre damit in jeder
anderen Sandbox sichtbar. Deshalb überspringt der Wrapper `skills` bewusst
(Details in [architektur.md](architektur.md#der-sonderfall-skills)).

Deine globalen Skills sind trotzdem **lesbar**, nur eben unter dem Host-Pfad:

```bash
sbx exec devbox-privat bash -c 'ls /Users/DEINNAME/.claude/skills'
```

Brauchst du einen davon, kopiere ihn nach `.claude/skills/` des Projekts — dort
wird er zuverlässig gefunden und ist nebenbei versioniert.

Wer den geteilten Store bewusst nutzen will:

```bash
sbx skills import
```

⚠️ Das wirkt auf **alle** Sandboxes des Rechners, nicht nur auf devbox.

---

## Plugins werden nicht geladen, obwohl der Ordner da ist

Der Ordner bringt die Registrierung mit (`installed_plugins.json`), aber nicht
die *Aktivierung* — die steht in `settings.json`, die wir bewusst nicht mounten.

Aktiviere das Plugin projektlokal:

```json
// <projekt>/.claude/settings.json
{
  "enabledPlugins": {
    "mattpocock-skills@claude-plugins-official": true
  }
}
```

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
  geändert hat.
- Aufräumen: `docker image prune` und alte `devbox/base`-Versionen entfernen.
- Wer Playwright nicht braucht: Schritt 7 aus dem Dockerfile entfernen, das
  spart mehrere GB.
