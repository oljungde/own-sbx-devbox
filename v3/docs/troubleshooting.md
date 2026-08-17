# Fehlersuche — sbx-claude

Nach Symptom sortiert. Die Überschrift ist möglichst wörtlich das, was du siehst.

Erste Anlaufstelle bei allem Unklaren:

```bash
sbx-claude doctor
sbx-claude check; echo "Stufe: $?"
```

## `sbx-claude: command not found`

Der Symlink fehlt oder `~/.local/bin` liegt nicht auf dem PATH.

```bash
./v3/sbx-claude.sh install
echo "$PATH" | tr ':' '\n' | grep local/bin
export PATH="$HOME/.local/bin:$PATH"   # dauerhaft in ~/.zshrc
```

## `permission denied: ./v3/sbx-claude.sh`

Das Ausführbar-Bit fehlt. Es lässt sich nicht über Git allein herstellen, wenn die
Datei ohne Bit eingecheckt wurde:

```bash
chmod +x v3/sbx-claude.sh v3/hooks/notify.sh v3/hooks/watch.sh
git update-index --chmod=+x v3/sbx-claude.sh v3/hooks/notify.sh v3/hooks/watch.sh
```

## `syntax error near unexpected token '<'`

Das Skript läuft nicht unter bash. `sh sbx-claude.sh` ignoriert die Shebang, und
`/bin/sh` ist auf macOS eine Bash 3.2 im POSIX-Modus ohne Prozess-Substitution.
Die eingebaute Prüfung startet sich normalerweise selbst neu — wenn du diese
Meldung siehst, ist die Prüfung aus dem Skriptkopf entfernt worden.

```bash
./v3/sbx-claude.sh up      # oder: bash v3/sbx-claude.sh up
```

## `shasum: /Users/du/.local/bin/Dockerfile: No such file or directory`

Der Aufruf kam über den Symlink, und die Symlink-Auflösung fehlt oder das Repo
wurde verschoben. Symlink neu setzen:

```bash
./v3/sbx-claude.sh install
```

## `cannot create temp file for here document`

Eine Stelle im Skript benutzt einen Here-String (`<<<`) oder ein Here-Doc, und
`/tmp` ist nicht schreibbar. Richtig ist Prozess-Substitution:

```bash
done < <(printf '%s\n' "$text")
```

## `ERROR: unknown flag: --version`

`sbx` kennt kein `--version`. Es heisst:

```bash
sbx version
```

## `Not authenticated to Docker` oder `sbx template ls` schlägt fehl

```bash
sbx login
```

Wichtig fürs Skripten: `sbx template ls` endet mit Exitcode 1, wenn man nicht
angemeldet ist. Jede Pipeline mit `sbx` in einer Zuweisung braucht deshalb
`|| true`, sonst bricht ein Skript mit `set -euo pipefail` stumm ab.

## `global network policy has not been initialized`

Einmalig pro Rechner:

```bash
sbx policy init balanced
```

Läuft auf dieser Maschine ein anderes sbx-Setup, sprich dich vorher ab — die
globale Policy gilt für alle Sandboxes.

## `ERROR: workspace path exists but is not a directory: /Users/du/.gitconfig`

sbx hängt nur **Verzeichnisse** ein, keine einzelnen Dateien. Deshalb wird die
Git-Identität als zwei Werte übertragen (`user.name`, `user.email`) und nicht als
Datei.

## `... can't be given new workspaces`

Mounts sind **nur beim Anlegen** setzbar. Es gibt keinen Weg, sie nachzurüsten:

```bash
cd ~/dev/own/projekt
sbx-claude rm
sbx-claude up          # und einmal /login
```

## `sbx create` bricht ab, weil ein Verzeichnis fehlt

sbx verweigert nicht existierende Workspaces. Der Wrapper legt die
`~/.claude`-Ordner und den Ereignisordner vorher mit `mkdir -p` an — wenn du von
Hand anlegst, musst du das selbst tun.

## Drei Sandboxes für ein Repo

Du hast wahrscheinlich `sbx create` von Hand in Unterordnern aufgerufen. Der
Wrapper bildet den Namen aus der **Git-Wurzel**, nicht aus dem aktuellen
Verzeichnis. Aufräumen:

```bash
sbx-claude status
sbx rm --force sbx-claude-src sbx-claude-test
```

## Zwei Projekte, gleicher Name

`~/dev/own/api` und `~/dev/work/api` heissen beide `api`. Der Wrapper merkt sich
pro Name den Pfad und hängt bei einer Kollision sechs Zeichen aus dem Pfad-Hash
an (`sbx-claude-api+3f9c1d`). Nachsehen:

```bash
sbx-claude status
cat ~/.local/state/sbx-claude/sbx-claude-api.pfad
```

## Projektlokale `CLAUDE.md` oder `.claude/` wird ignoriert

Claude liest sie beim **Start** aus dem Arbeitsverzeichnis. Ein `cd` in der
laufenden Sitzung holt das nicht nach. Prüfen, wo Claude gestartet ist:

```bash
sbx exec sbx-claude-api pwd
```

`sbx-claude up` benutzt `sbx exec -w <projektwurzel>`. Wer `sbx run` benutzt,
landet im Primary Workspace — und sieht die projektlokale Konfiguration nicht.

## Globale Skills tauchen nicht auf, Agents und Commands schon

Skills laufen über sbx' Store, nicht über den Mount. Zwei Ursachen:

```bash
sbx settings get feature.shareSkills --json    # muss enabled:true zeigen
sbx skills import --dry-run                    # was würde importiert?
```

Ist das Flag aus, schreibt `sbx skills import` in einen Store, den keine Sandbox
einhängt — also wirkungslos. `sbx-claude up` fragt einmal, ob es eingeschaltet
werden soll; wer damals „nein" gesagt hat, sagt jetzt:

```bash
sbx settings set feature.shareSkills true
sbx-claude rm && sbx-claude up      # bestehende Boxen bekommen den Store erst neu
```

## Ein neuer Skill auf dem Host fehlt in der Sandbox

```bash
sbx-claude sync
```

## Andere Sandboxes sehen meine globalen Skills

Das ist die Bauart, kein Fehler: der Store ist maschinenweit und **read-write**
von allen Sandboxes geteilt. Wer das für ein Projekt nicht will:

```bash
# in ~/.config/sbx-claude/sbx-claude.conf
ISOLATE_SKILLS=1
```

Dann `rm` und `up` — die Flag wirkt nur beim Anlegen.

## `/plugin install` scheitert in der Sandbox

`~/.claude/plugins` ist absichtlich read-only eingehängt. Installiert wird auf dem
Host:

```bash
# auf dem Host
claude       # /plugin install …
sbx-claude sync
```

## Agents oder Commands tauchen nicht auf, obwohl eingehängt

Die Symlink-Brücke fehlt. sbx hängt am **Host**-Pfad ein, `$HOME` im Container ist
aber `/home/agent`:

```bash
sbx exec sbx-claude-api ls -la /home/agent/.claude/
sbx-claude sync
```

## MCP-Server steht auf `failed` oder ewig auf `connecting`

Mit Abstand häufigste Ursache ist die Netz-Policy:

```bash
sbx policy log sbx-claude-api
sbx policy check network --sandbox sbx-claude-api mcp.linear.app
sbx-claude allow mcp.linear.app        # zum Ausprobieren
```

Danach den Host dauerhaft als `EXTRA_HOSTS` eintragen. Bei einem stdio-Server aus
einem Plugin (`npx …`) kommt als zweite Ursache eine blockierte Registry in
Frage: `*.npmjs.org` muss freigegeben sein.

## Ein Netzaufruf scheitert und du weisst nicht, welcher Host fehlt

```bash
sbx policy log sbx-claude-api --limit 50
```

Das protokolliert, welche Hosts erlaubt und welche blockiert wurden.

## Nach jeder Antwort erscheint ein Hook-Fehler mit `osascript`

Ein Notification- oder Stop-Hook vom Host ist in die Sandbox gelangt. Diese
Variante soll das gerade **nicht** tun — sie besetzt diese Ereignisse selbst.
Prüfen, was in der Box steht:

```bash
sbx exec sbx-claude-api cat ~/.claude/settings.json
```

Unter `hooks` müssen bei `Notification`, `Stop` und `UserPromptSubmit` Pfade nach
`/usr/local/bin/sbx-claude-notify` stehen. Wenn dort
`$HOME/.claude/hooks/notify.sh` steht, ist `HOOK_UEBERNEHMEN` zu weit gefasst —
diese drei Ereignisse gehören nicht hinein.

## Es kommt keine Benachrichtigung an

In dieser Reihenfolge:

```bash
sbx-claude doctor                                  # läuft der Wächter?
ls -la ~/.local/state/sbx-claude/events/           # kommen Ereignisse an?
sbx exec sbx-claude-api cat ~/.claude/settings.json | grep notify
sbx exec sbx-claude-api ls -l /usr/local/bin/sbx-claude-notify
tail -20 ~/.local/state/sbx-claude/watch.log
command -v terminal-notifier osascript
```

Die dritte Zeile ist die interessante: dort stehen Ereignisordner, Sandbox-Name
und Schwelle als Argumente im Hook-Aufruf. Stimmt der Pfad nicht mit dem
tatsächlichen Mount überein, schreibt der Hook ins Leere.

Häufigste Ursachen, in dieser Häufigkeit:

1. Der Wächter läuft nicht → `sbx-claude install --watcher`
2. Der Hook-Aufruf hat den falschen Pfad → `sbx-claude sync`
3. Der Ereignisordner ist nicht eingehängt → `sbx-claude rm` und `up`
4. Die Antwort war kürzer als `NOTIFY_SCHWELLE` → so gewollt

## Meldungen kommen, aber viel zu viele

`NOTIFY_SCHWELLE` ist zu niedrig. Der `Stop`-Hook feuert nach jeder Antwort;
gemeldet wird nur, was länger gedauert hat.

```bash
# in ~/.config/sbx-claude/sbx-claude.conf
NOTIFY_SCHWELLE=180
```

Dann `sbx-claude sync`.

## Die gemeldeten Dauern sind Unsinn

Wahrscheinlich läuft eine sehr alte Fassung des Hooks, die eine feste Startmarke
benutzte. Bei zwei gleichzeitigen Sitzungen in einer Sandbox überschreibt dann
eine die Startzeit der anderen. Aktuell trägt die Marke die Sitzungskennung im
Namen:

```bash
sbx exec sbx-claude-api ls /tmp/sbx-claude-start-*
```

## `notify.sh: line NN: /dev/tty: Device not configured`

Die Terminal-Glocke wurde ohne Terminal aufgerufen und die Fehlermeldung nicht
abgefangen. Die Umleitung muss die **Shell** einschliessen, nicht nur `printf`:

```sh
{ printf '\a' > /dev/tty; } 2>/dev/null || true
```

## Claude fragt nicht vor einem git-Kommando

Drei Möglichkeiten, in dieser Reihenfolge:

```bash
sbx exec sbx-claude-api cat ~/.claude/settings.json   # steht das Verb in "ask"?
```

1. Das Verb fehlt in `GIT_ASK_VERBEN`. Ergänzen und `sbx-claude sync`.
2. Das Muster ist als `Bash(git VERB *)` geschrieben statt `Bash(git *VERB*)` —
   dann rutscht `git -C unterordner commit` durch.
3. Das Kommando lief indirekt (`npm run release`, ein Skript, `python
   subprocess`). Das ist nicht erkennbar, und die Doku behauptet es auch nicht.

Was **kein** Grund ist: eine Kette oder eine Substitution. Nachgemessen greifen
Regeln auf jedes Segment und auch in `$(…)` — `cd repo && git push` fragt also.
Nachprüfbar ohne Sandbox mit einer `deny`-Regel, die du ohnehin hast:

```bash
# mit deny: ["Bash(env)"] in der settings.json
cd /tmp && env      # muss blockiert werden
```

## Claude fragt zu oft bei git

Das ist der Preis der breiten Muster: `Bash(git *push*)` trifft auch
`git log --grep=push`. Wer es enger will, nimmt einzelne Verben aus
`GIT_ASK_VERBEN` heraus — und weiss dann, dass globale Optionen davor
durchrutschen.

## Claude schreibt in `.git/`, ohne zu fragen

Prüfen, ob die deny-Regeln da sind:

```bash
sbx exec sbx-claude-api cat ~/.claude/settings.json | grep -A4 deny
```

`bypassPermissions` schaltet laut Dokumentation den Schutz der „protected paths"
wie `.git` ab. Es müssen `Edit(.git/**)` und `Write(.git/**)` explizit unter
`deny` stehen.

⚠️ Über die **Shell** ist `.git/` dagegen nicht geschützt: `echo x > .git/config`
läuft durch. Diese Lücke ist bewusst in Kauf genommen — sie zu schliessen hätte
einen eigenen Hook mit einer Regex über die ganze Kommandozeile gebraucht, und
der stand in einer früheren Fassung hier und ist wieder gelöscht worden (siehe
Kapitel 5). Wer die Historie zerstören will, kann `rm -rf .git`, und das fängt
`Bash(rm -rf *)`.

## `npm install safe-chain-test` wird nicht blockiert

```bash
sbx exec sbx-claude-api bash -lc 'command -v npm; echo "$PATH"'
```

`/opt/safe-chain/shims` muss im PATH **vor** dem echten npm stehen. Ist
`SBX_CLAUDE_SAFE_CHAIN=0` gesetzt, ist der Schutz absichtlich aus.

Der eigentliche Test ist der mit Hülle:

```bash
timeout 60 npm install safe-chain-test
```

Wird der durchgelassen, sind Shell-Funktionen statt Shims im Einsatz — das ist
eine Lücke, nicht Kosmetik.

## `pnpm --version` zeigt eine Corepack-Download-Meldung

Im Dockerfile wurde pnpm über `corepack` aktiviert. Corepack legt das im Cache des
Bau-Users ab, `agent` kommt nicht heran und lädt still eine andere Version nach.
Richtig ist `npm install -g pnpm@<version>`, dann neu bauen:

```bash
sbx-claude update
```

## Ein neues Werkzeug fehlt, obwohl das Image neu gebaut ist

Das ist **der** Klassiker dieser Variante: ein neues Template erreicht bestehende
Sandboxes nicht.

```bash
sbx-claude update      # baut neu UND nennt jede betroffene Box samt Befehlszeile
cd ~/dev/own/projekt
sbx-claude rm && sbx-claude up
```

`up` warnt seit der aufgeräumten Fassung nicht nur, sondern **fragt**, ob es das
Image neu bauen soll, wenn es älter als das Dockerfile ist. Erst danach prüft es
die Sandbox dagegen — umgekehrt legte man die Box neu an und sie hinge sofort
wieder am alten Image.

## `check` sagt „Stand unbekannt"

Die Box ist gestoppt, und es gibt keine Stempel-Notiz vom Anlegen — sie wurde von
Hand angelegt oder der Zustandsordner ist weg. Der Stempel *in* der Box wird
absichtlich nur gelesen, wenn sie läuft: `sbx exec` würde sie sonst starten, und
ein blosses `status` bootet dann jede Box.

Sicherheit gibt ein Start:

```bash
sbx-claude shell        # startet die Box
exit
sbx-claude check        # jetzt wird der Stempel in der Box gelesen
```

## `check` sagt „ÄLTERES Image … (Notiz)"

Die Auskunft kommt aus der Notiz vom Anlegen, nicht aus der Box — sie ist
gestoppt. Das ist normal und die Aussage stimmt in der Regel. Wer der Notiz nicht
traut (von Hand editiert, Repo umgezogen), lässt die Box starten und prüft erneut;
der Stempel in der Box gewinnt immer:

```bash
sbx-claude shell && exit
sbx-claude check
```

## `check` sagt „Image trägt keinen Stempel"

Das Image wurde ohne `--build-arg SBX_CLAUDE_STAMP=…` gebaut, also nicht über den
Wrapper.

```bash
sbx-claude build --force
```

## `check` sagt „kein Template im Store", obwohl gebaut

Die Merkdatei auf dem Host stimmt, aber der sbx-Store ist leer — anderer Rechner,
`sbx reset` oder Handarbeit. Der `docker save`/`sbx template load`-Schritt fehlt:

```bash
sbx-claude build --force
```

## Der erste Start läuft ohne Berechtigungsgrenzen

Dann wurde `sbx run` benutzt. Es startet den Agenten mit
`--dangerously-skip-permissions`. Richtig ist:

```bash
sbx exec -it -w "$PWD" sbx-claude-api claude
```

Genau das tut `sbx-claude up`, auch beim ersten Start.

## `git push` scheitert mit Authentifizierungsfehler

```bash
sbx secret ls | grep -i github
gh auth token | sbx secret set github
```

Fehlt das Geheimnis, kann nichts nach aussen — auch `gh` bleibt unangemeldet.

## Der Bau dauert ewig oder die Platte läuft voll

Chromium ist dabei, und der komplette Tarball geht bei **jedem** Bau durch
`docker save` in den sbx-Store. Aufräumen:

```bash
docker image prune
docker system df
sbx template ls
sbx template rm <alter-tag>
```

Wer Chromium nicht braucht, kommentiert den Playwright-Block im Dockerfile aus —
und weiss, dass Nachrüsten pro Projekt eine Neuanlage kostet.

## Nach `rm` ist die Anmeldung weg

So ist es. Die Anmeldung liegt in einem Volume der Sandbox, nicht auf dem Host.
Auf dem Mac liegt dein Login im Keychain und lässt sich nicht einhängen. Einmal
`/login` pro neuer Box ist der Preis dieser Aufteilung.
