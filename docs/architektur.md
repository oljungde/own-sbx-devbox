# Architektur — das Warum hinter den Entscheidungen

Das Tutorial erklärt, _wie_ devbox gebaut wird. Dieses Dokument erklärt, _warum_
es so und nicht anders gebaut ist. Wenn du das Projekt umbauen willst, lies das
hier zuerst.

---

## Die drei Ebenen

```bash
Dockerfile  --docker build-->  Image  --sbx template load-->  Template
                                                                 |
                                                        sbx create -t
                                                                 v
                                                              Sandbox
```

Das **Template ist teuer** (Minuten, Gigabyte), die **Sandbox ist billig**
(Sekunden). Daraus folgt die Grundform: _ein_ Template pro Rechner, _mehrere_
Sandboxes daraus.

Der Umweg über `docker save` existiert, weil der Docker-Daemon von `sbx` nicht
derselbe ist wie dein lokaler und dessen Image-Store nicht sieht.

---

## Wrapper statt Kit

`sbx` bietet ein deklaratives Kit-Format an. Es liest sich besser als Bash. Wir
benutzen es trotzdem nicht als Fundament:

```bash
$ sbx kit --help
EXPERIMENTAL: this command may change or be removed in future releases.
```

Für Material, das über Monate in einem Kurs benutzt wird, ist das ein
inakzeptables Risiko. Entscheidend war aber ein zweiter Befund: **Es gibt nichts,
was ein Kit kann und ein stabiles Kommando nicht.**

| Kit-Feature           | Stabile Entsprechung                 |
| --------------------- | ------------------------------------ |
| `permissions.network` | `sbx policy allow network --sandbox` |
| `credentials`         | `sbx secret`                         |
| Umgebungsvariablen    | `/etc/sandbox-persistent.sh`         |
| Startup-Kommandos     | `sbx exec -d`                        |

Ein Kit ist also Bequemlichkeit, kein Ermöglicher. Es liegt als
[`devbox/kit/kit.yaml`](../devbox/kit/kit.yaml) bei, damit man es kennenlernen
kann — aber nichts hängt davon ab.

**Dasselbe gilt für `sbx skills`** (ebenfalls EXPERIMENTAL). Siehe unten.

---

## Mounten statt kopieren

Skills und Agents, die man in _allen_ Projekten braucht, in _jedes_ Projekt zu
kopieren, erzeugt so viele Wahrheiten, wie es Projekte gibt. Nach kurzer Zeit
laufen sie auseinander.

Deshalb: read-only mounten, eine Quelle.

**Warum nicht `sbx skills import`?**

|               | `sbx skills import`      | `:ro`-Mount                              |
| ------------- | ------------------------ | ---------------------------------------- |
| Aktualität    | Kopie, Re-Import nötig   | live                                     |
| Schreibrechte | Store ist **read-write** | read-only                                |
| Umfang        | nur `skills`             | skills, agents, commands, rules, plugins |
| Stabilität    | EXPERIMENTAL             | stabile Flags                            |

Die zweite Zeile ist die wichtigste — und beim Bauen dieses Repos nachgemessen:
Der Store ist beschreibbar und wird von **allen** Sandboxes der Maschine geteilt.
Eine Sandbox kann darüber die Konfiguration aller anderen verändern. Das
widerspricht dem Zweck einer Sandbox.

### Der Sonderfall `skills`

`sbx` hängt seinen Store an **genau den Pfad**, an den auch unser Symlink
gehört: `/home/agent/.claude/skills`. Sichtbar schon beim Anlegen:

```bash
skills  .../com.docker.sandboxes/sandboxes/agent-skills → /home/agent/.claude/skills
```

Ein `ln -sfn` dorthin **schlägt nicht fehl** — es meldet Erfolg und legt den Link
_in_ das eingehängte Verzeichnis. Damit läge unsere Konfiguration in jeder
anderen Sandbox des Rechners. Ein stiller Seiteneffekt über Sandbox-Grenzen
hinweg, der ohne einen praktischen Test unentdeckt geblieben wäre.

Konsequenz im Wrapper: zwei getrennte Listen (`CLAUDE_SHARED` zum Mounten,
`CLAUDE_LINKED` zum Verlinken, ohne `skills`) plus eine Sicherung, die jedes Ziel
überspringt, das bereits ein echtes Verzeichnis ist.

Der Preis: Globale Skills sind in der Sandbox unter ihrem Host-Pfad **lesbar**,
werden aber nicht automatisch als User-Skills gefunden. Wer einen davon braucht,
legt ihn projektlokal unter `.claude/skills/` ab — womit er nebenbei versioniert
und im Team geteilt ist.

Ein `--no-share-skills`-Flag erwähnt `sbx skills --help`. In `sbx create --help`
und `sbx run --help` taucht es **nicht** auf — angenommen wird es von beiden
trotzdem. Nachgemessen in v0.38.0 über die Fehlermeldung, die zurückkommt:

```bash
$ sbx create --no-share-skills claude
ERROR: requires at least 1 argument: PATH      # Flag akzeptiert, Pfad fehlt

$ sbx create --share-skills claude
ERROR: unknown flag: --share-skills            # Gegenprobe: so sieht Ablehnung aus
```

Es ist also ein verstecktes Flag, das zum EXPERIMENTAL-Kommando `sbx skills`
gehört. Für `devbox` bleibt es damit außen vor — die Regel „nur stabile Flags im
kritischen Pfad" gilt erst recht für eines, das nicht einmal in der Hilfe steht.
`solobox` benutzt es hinter einem Schalter, siehe unten.

### Die Ausnahme: `SHARE_ALL`

Jede der Trennungen oben hat genau eine Begründung: **fremde Sandboxes auf
derselben Maschine**. Fällt dieses Gegenüber weg — weil dort nur die eigenen
Sandboxes laufen — verteidigen sie nichts mehr und kosten nur noch Nacharbeit.

Deshalb gibt es `SHARE_ALL=1` als Profil-Variable. Sie kopiert die globalen
Skills in den geteilten Store und aktiviert alle installierten Plugins über eine
`settings.json`, die der Wrapper **in** der Sandbox erzeugt.

Drei Entscheidungen dazu:

- **Standard ist aus.** Wer nichts einträgt, bekommt die getrennte Variante. Der
  Schalter soll eine Entscheidung sein, kein Zustand, in den man hineinrutscht.
- **Im Profil, nicht im Skript.** Ob die Grenze zu anderen Sandboxes gebraucht
  wird, hängt an der Maschine, nicht am Wrapper. Diese Frage kann nur der
  beantworten, der den Rechner kennt.
- **Die Host-`settings.json` bleibt trotzdem draußen.** Die erzeugte Datei
  enthält nur `enabledPlugins`. Diese eine Trennung kostet nichts, also geben
  wir sie auch im Bequemlichkeitsmodus nicht auf.

Der Preis steht in [Kapitel 6](tutorial/06-globale-und-lokale-config.md#alles-auf-einmal--und-was-es-kostet):
geteilter, beschreibbarer Store und Kopie statt Live-Mount.

**Warum `:ro` und nicht `~/.claude` komplett?**

- `.credentials.json` hat in einem Container nichts verloren.
- `settings.json` enthält Berechtigungen für den **Host**. Im Container passen
  sie nicht und können mehr erlauben, als beabsichtigt.
- Ohne `:ro` könnte ein Agent globale Skills verändern, die dann auf dem Host
  für **alle** Projekte gelten — ein Weg aus der Sandbox heraus.

**Warum Symlinks?** Extra-Workspaces werden unter ihrem absoluten _Host_-Pfad
eingehängt (`/Users/du/.claude/skills`), Claude sucht aber in
`/home/agent/.claude/skills`. Der Symlink verbindet beides.

---

## Dach-Ordner statt Einzelprojekte

Workspaces können **nur beim Anlegen** einer Sandbox gesetzt werden. Nachrüsten
bedeutet `sbx rm` — und damit Verlust von Login und Laufzeitzustand.

Ein Dach-Ordner (`~/dev/own`) statt einzelner Projekte macht diesen Fall
unmöglich: alles, was du künftig darunter anlegst, ist automatisch dabei.

Der Preis: Die Sandbox sieht alle Projekte darunter, auch während sie an einem
einzigen arbeitet. Wer das nicht will, mountet gezielter oder trennt in mehrere
Sandboxes.

---

## Netzregeln nur pro Sandbox

`sbx policy allow network <host>` wirkt **global** — auf alle Sandboxes des
Rechners, auch auf die anderer Setups. `--sandbox <name>` wirkt nur lokal.

devbox benutzt **ausschließlich** die sandbox-scoped Variante. Damit ist
garantiert, dass ein paralleles Sandbox-Setup auf derselben Maschine unberührt
bleibt.

Die Liste ist bewusst **kurz** (neun Einträge). Eine lange Union-Liste aller je
gebrauchten Hosts nimmt den Lerneffekt weg: Zu erleben, dass der Agent nicht
herauskommt, und zu wissen wie man das ändert, ist selbst Teil des Stoffs.

---

## Kollisionsschutz

devbox ist so benannt, dass es sich mit keinem anderen `sbx`-Setup überschneidet:

|                | devbox                  | Typische Alternative |
| -------------- | ----------------------- | -------------------- |
| Ordner im Repo | `devbox/`               | `sbx/`               |
| Sandbox-Namen  | `devbox-*`              | `claude-*`           |
| Template       | `devbox/base`           | agent-spezifisch     |
| Zustand        | `~/.local/state/devbox` | anderswo             |

Der Ordnername ist kein Detail: Manche Wrapper erkennen ein Verzeichnis namens
`sbx/` im Git-Root **automatisch** und schalten daraufhin in einen Sondermodus
oder delegieren an ein dort liegendes Skript. Ein eigener Name verhindert, dass
zwei Systeme sich gegenseitig kapern.

---

## Safe Chain: eigene Shims

Statt den Installer seine Shims setzen zu lassen, erzeugt das Dockerfile sie
selbst — sechs Dateien mit je zehn Zeilen.

Drei Gründe:

1. **Sichtbarkeit.** Man kann `cat /opt/safe-chain/shims/npm` machen und in
   zehn Sekunden verstehen, was passiert.
2. **Schaltbarkeit.** Der Schutz hängt an genau einem PATH-Eintrag, also an
   einer `if`-Zeile in `/etc/sandbox-persistent.sh`. `DEVBOX_SAFE_CHAIN=0`
   schaltet ihn ab.
3. **Kein Selbstaufruf.** Jeder Shim entfernt sein eigenes Verzeichnis aus dem
   PATH, bevor er das echte Werkzeug ruft. Ohne das würde `aikido-npm` wieder
   unseren `npm`-Shim finden.

Der `else`-Zweig lässt `npm` mit einer Warnung durchlaufen, wenn Safe Chain
fehlt. Ein Schutz, der im Fehlerfall die Arbeit blockiert, wird umgangen — und
ein umgangener Schutz schützt nicht.

---

## pnpm nicht über corepack

`corepack prepare pnpm@X --activate` schreibt in den Cache des **Bau-Users**
(`root`). Zur Laufzeit läuft `agent`, sieht davon nichts und lädt beim ersten
Aufruf eine andere Version aus dem Netz.

Das ist beim Bauen dieses Images tatsächlich passiert und nachgemessen worden:
festgelegt war 10.11.0, im Container kam 11.21.0 an — mit Download zur Laufzeit.

`npm install -g pnpm@10.11.0` landet in `/usr/local/share/npm-global` und ist
für alle User sichtbar und fest.

---

## Variante 2: solobox — genau eine Sandbox

`solobox` beantwortet dieselbe Frage anders. Nicht besser, anders. Der Handel:
**Bequemlichkeit gegen Trennung.**

### Warum überhaupt eine zweite Variante

devbox trennt über Profile. Das ist sauber, kostet aber bei jedem neuen Vorhaben
eine Entscheidung, einen Eintrag und einen eigenen Login. Wer auf einer Maschine
ohnehin nur mit sich selbst arbeitet, zahlt diesen Preis ohne Gegenwert.

solobox dreht die Voreinstellung um: eine Sandbox, ein Login, und alles Globale
aus `~/.claude` ist immer dabei — inklusive Hooks und Plugins, die devbox selbst
im `SHARE_ALL`-Modus nicht anfasst.

### Die zentrale Mechanik: `sbx exec -w`

Eine Sandbox für alle Projekte hat ein Problem, das devbox nicht hat: `sbx run`
startet den Agenten im **Primary Workspace**. Claude Code liest die
projektlokale Konfiguration aber beim **Start** aus dem Arbeitsverzeichnis — ein
`cd` in der laufenden Sitzung holt sie nicht nach. Eine Sandbox mit
Dach-Ordner-Mount würde also _immer_ ohne Projektkontext starten.

Die Lösung hängt an einer Eigenschaft, die devbox nur nebenbei nutzt: zusätzliche
Workspaces werden unter ihrem **absoluten Host-Pfad** eingehängt. Host-Pfad und
Sandbox-Pfad sind identisch, und damit stimmt:

```bash
cd ~/dev/own/projekt
sbx exec -it -w "$PWD" solobox claude
```

Das ist der eigentliche Unterschied der Variante — kein Bild, kein Flag, ein
Arbeitsverzeichnis.

Der Preis: `sbx exec` ist nicht der von `sbx` vorgesehene Weg, einen Agenten zu
starten (`sbx run` ist es). Deshalb steht der Vergleich beider Startarten als
ausdrücklicher Prüfschritt im
[Tutorial-Kapitel 1](tutorial-solo/01-die-eine-sandbox.md), und der erste Start
nach dem Anlegen läuft über `sbx run` — dort passiert der Login.

### `settings.json`: ableiten statt mounten

devbox lässt die Host-`settings.json` komplett draußen und erzeugt im
`SHARE_ALL`-Modus eine mit _nur_ `enabledPlugins`. solobox braucht mehr, weil es
auch Hooks mitbringen soll — nimmt aber weiterhin nicht die Datei selbst,
sondern leitet ab:

| Übernommen                                 | Warum                                                           |
| ------------------------------------------ | --------------------------------------------------------------- |
| `enabledPlugins`, `extraKnownMarketplaces` | gehören zusammen, sonst findet die Sandbox den Marktplatz nicht |
| `model`, `effortLevel`                     | reine Vorlieben, host-unabhängig                                |
| `hooks` abzüglich `HOOK_SKIP`              | siehe unten                                                     |

| Gesetzt statt kopiert                                                                | Warum                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `permissions.defaultMode` (Standard `acceptEdits`, per `PERMISSION_MODE` umstellbar) | in der Sandbox darf Claude Dateien ohne Rückfrage ändern — aber **nicht** `bypassPermissions`, weil `~/dev` echt eingehängt und beschreibbar ist. Die Sandbox schützt den Host, nicht die Projekte. |

Dazu ein Detail, das man nur beim Hineinsehen findet: Das Image hinterlässt
seinen Modus auf der **obersten** Ebene der `settings.json`
(`"defaultMode": "bypassPermissions"` plus `"bypassPermissionsModeAccepted"`),
während der dokumentierte Schlüssel `permissions.defaultMode` heißt. Setzt man
nur letzteren, behauptet die Datei zweierlei — und welche Angabe gewinnt, ist
nicht dokumentiert. solobox entfernt deshalb die Schlüssel des Images, sobald
ein anderer Modus gewünscht ist, und setzt bei `bypassPermissions` beide Ebenen
gleichlautend. Nicht die elegantere Lösung, aber die einzige, die eine eindeutige
Datei hinterlässt.

Nicht prüfbar per `claude --print`: der Kopfmodus setzt Berechtigungen nicht
durch (ein Bash-Aufruf läuft dort selbst mit `--permission-mode default`).

### Wo die Bremse wirklich sitzt

Die Suche nach der Rückfrage bei einem Bash-Aufruf führte durch drei Schichten,
und die Antwort liegt in keiner davon, wo man sie vermutet:

1. **`sbx run` startet den Agenten mit `--dangerously-skip-permissions`** (mit
   `ps` in der Sandbox nachgemessen). In dieser Sitzung ist die `settings.json`
   gegenstandslos. Betrifft bei solobox nur den ersten Start nach dem Anlegen —
   danach läuft alles über `sbx exec … claude`, ohne Flag.
2. **Claude Code betreibt in der Sandbox seinen eigenen Bash-Sandkasten** und
   lässt darin laufende Befehle ohne Rückfrage zu (`autoAllowBashIfSandboxed`).
   Deshalb fragt auch eine Sitzung ohne Flag bei `date` nicht nach.
3. **Die wirksame Grenze ist das Arbeitsverzeichnis.** Nachgemessen aus einer in
   `~/dev/own` gestarteten Sitzung: `touch ~/dev/own/PROBE` gelingt,
   `touch /home/agent/PROBE` wird abgewiesen mit „Schreibzugriff außerhalb des
   erlaubten Arbeitsverzeichnisses blockiert".

Daraus folgt die eigentliche Rechtfertigung für `sbx exec -w "$PWD"`: Sie ist
nicht nur der Weg, projektlokale Konfiguration zu laden, sondern **auch die
Sicherheitsgrenze**. Wer im Projekt startet, dessen Agent kann nur in diesem
Projekt schreiben; wer in `~/dev` startet, gibt ihm alle Projekte.

`PERMISSION_MODE` bleibt trotzdem sinnvoll — für alles, was der innere
Sandkasten nicht abdeckt, und als Schalter zurück auf `bypassPermissions`. Wer
Rückfragen auch für sandkastenfähige Befehle will, nimmt
`"sandbox": {"autoAllowBashIfSandboxed": false}` in die abgeleitete Datei auf.
Bewusst nicht voreingestellt: eine Rückfrage pro `ls` ist Reibung ohne
Gegenwert, solange der Radius ohnehin das Projekt ist.

| Draußen                             | Warum                                                            |
| ----------------------------------- | ---------------------------------------------------------------- |
| `permissions.allow/deny`, `sandbox` | Pfade und Regeln des Hosts, im Container bestenfalls wirkungslos |
| `theme`, `voice`, `tui`             | gerätespezifisch                                                 |

### Hooks sind nicht portabel

Der Grund für `HOOK_SKIP`: Ein Hook, der `osascript` oder `terminal-notifier`
aufruft, kann im Container nicht funktionieren — und weil solche Skripte
üblicherweise mit `set -e` laufen, endet der Hook nicht still, sondern mit einem
Fehler bei **jeder** Antwort. Ein Hook dagegen, der nur `jq` und die
Hook-Eingabe benutzt (etwa ein `.env`-Blocker), läuft überall.

Deshalb steht `jq` im Dockerfile und `HOOK_SKIP=(Notification Stop)` in den
Voreinstellungen. Es ist eine Liste, keine Heuristik: raten, welcher Hook
portabel ist, geht schief.

### `ISOLATE_SKILLS`: die eine Flag-Ausnahme

Skills lassen sich nicht verlinken (siehe [oben](#der-sonderfall-skills)), also
kopiert solobox sie — und landet damit im geteilten Store. Für den Fall, dass
das nicht gewollt ist, gibt es `--no-share-skills`. Drei Entscheidungen dazu:

- **Standard ist der stabile Weg**, nicht der bequeme: ohne Flag, mit Kopie in
  den geteilten Store. Ein undokumentiertes Flag gehört nicht in den Pfad, den
  jeder Lernende geht.
- **Der Schalter prüft, bevor er handelt.** `supports_no_share_skills()` fragt
  `sbx create` ohne Pfad an: kommt „requires at least 1 argument", ist das Flag
  bekannt; kommt „unknown flag", nicht. So lässt sich ein verstecktes Flag
  testen, ohne etwas anzulegen.
- **Fällt das Flag weg, bricht nichts.** Der Wrapper fragt dann nach, statt
  abzubrechen oder stillschweigend in den geteilten Store zu schreiben.

### Was solobox aufgibt

| Aufgegeben                    | Konsequenz                                  |
| ----------------------------- | ------------------------------------------- |
| Trennung privat/beruflich     | eine Sandbox sieht alles unter der Wurzel   |
| Getrennte Netzregeln          | eine Liste für alles                        |
| Getrennter Laufzeitzustand    | globale npm-Pakete teilen sich eine Sandbox |
| Wahlfreiheit beim zweiten Mal | `ROOTS` steht nach dem Anlegen fest         |
| Trennung zum Skill-Store      | Standard ist geteilt (umschaltbar)          |

Was **nicht** aufgegeben wird, weil es nichts kostet: `.credentials.json` bleibt
draußen, `settings.json` wird nicht gemountet, Netzregeln bleiben
`--sandbox`-scoped, und `~/.claude` ist ausschließlich `:ro` eingehängt.

---

## Was bewusst _nicht_ gemacht wurde

| Nicht gemacht                               | Warum                                                                   |
| ------------------------------------------- | ----------------------------------------------------------------------- |
| Zentrales Image in einer Registry           | Jeder soll sein eigenes Repo und Image besitzen und frei ändern können  |
| Automatische Repo-Erkennung per Git-Remote  | Erzeugt eine Sandbox pro Projekt — genau das, was wir loswerden wollten |
| Globale Netz-Policy                         | Würde parallele Setups mitverändern                                     |
| `settings.json` mounten                     | Host-Berechtigungen gehören nicht in einen Container                    |
| `sbx kit` / `sbx skills` im kritischen Pfad | EXPERIMENTAL                                                            |
