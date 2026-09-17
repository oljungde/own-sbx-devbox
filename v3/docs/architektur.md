# Architektur — das Warum hinter sbx-claude

Diese Datei begründet die Entscheidungen. Wer nur arbeiten will, braucht das
[Cheatsheet](cheatsheet.md). Wer eine Entscheidung ändern will, sollte hier
nachlesen, was sie getragen hat.

## Die drei Ebenen

```
Dockerfile  ->  Image  ->  Template im sbx-Store  ->  Sandbox
   Text        unveränderlich    registriert          läuft, hat Mounts
```

Jeder Pfeil ist eine Einbahnstrasse. Ein geändertes Dockerfile ändert kein Image,
ein neues Image keine laufende Sandbox. Fast alles Verwirrende an diesem Aufbau
folgt aus diesen zwei Sätzen — und die Drift-Prüfung existiert, um sie sichtbar zu
machen.

## Die Grenze soll dort verlaufen, wo die Projektgrenze verläuft

Die beiden Schwestervarianten setzen die Sandbox-Grenze woanders: `v1/` pro
Profil, `v2/` genau einmal systemweit. Beides funktioniert und beides hat
denselben Bruch — mehrere Projekte teilen eine Box. Ein Agent, der in Projekt A
arbeitet, sieht Projekt B.

Hier ist die Aufteilung deckungsgleich mit der Projektaufteilung: eine Box pro
Projekt. Was das kostet, steht weiter unten unter „Was diese Variante aufgibt" —
es ist nicht wenig, und es ist der Grund, warum die anderen Varianten weiter
existieren.

Ein **gemeinsames Image** ist dabei kein Kompromiss, sondern die Voraussetzung:
`-t/--template` ist nur eine Image-Referenz, nichts bindet ein Image an eine
Sandbox. Zehn Boxen kosten also einmal Bauzeit, nicht zehnmal.

## Warum `sbx run` nirgends vorkommt

Das ist die folgenreichste Einzelentscheidung.

`sbx run` startet den Agenten mit `--dangerously-skip-permissions` — in der
Schwestervariante mit `ps` in der Sandbox nachgemessen. In einem Setup mit einer
Sandbox ist das ein einmaliges Ärgernis beim allerersten Start; `solobox`
dokumentiert es als Warnung und lebt damit.

Bei einer Box pro Projekt wäre es der **Normalfall**: jedes neue Projekt beginnt
mit einer Sitzung ohne Berechtigungsgrenzen. Damit wäre das ganze Kapitel 5
Dekoration.

`sbx exec -it -w PFAD SANDBOX claude` startet Claude genauso, und `/login`
funktioniert darin. Also gibt es `sbx run` in diesem Wrapper nicht — auch nicht
beim Anlegen. Der Preis ist genau nichts.

`-w` ist im selben Aufruf die zweite Notwendigkeit: Claude Code liest `CLAUDE.md`,
`.claude/` und `.mcp.json` beim **Start** aus dem Arbeitsverzeichnis. Ein `cd` in
der laufenden Sitzung holt das nicht nach.

## bypass plus ask: warum diese Kombination und nicht eine der beiden Hälften

Die naheliegenden Positionen sind beide schlecht:

**„Alles fragen"** klingt sicher und ist es nicht. `acceptEdits` fragt bei jedem
Bash-Kommando, `default` zusätzlich bei jedem Edit. Man bestätigt das nach zwei
Sitzungen reflexhaft. Eine Rückfrage, die man nicht liest, schützt nichts — sie
ist schlechter als keine, weil sie Sicherheit vortäuscht.

**„Nichts fragen"** ist bei einem Bind-Mount fahrlässig. Der Container schützt das
System, nicht das Repo: `rm -rf`, `git reset --hard`, `git push --force` treffen
echte Dateien und echte Remotes. Die Netz-Policy verhindert, dass Daten
**hinausgehen**; gegen **Zerstörung** hilft sie nicht.

Die Auflösung steckt in einer Eigenschaft, die die Dokumentation ausdrücklich
zusagt:

> „These controls apply in every mode, including `bypassPermissions`: deny rules
> and explicit ask rules"

Damit lässt sich das Rückfrage-Budget dort ausgeben, wo etwas unumkehrbar ist, und
nirgends sonst. Die Reihenfolge ist `deny`, dann `ask`, dann `allow`.

Zwei Ergänzungen, ohne die es lückenhaft wäre:

- **`deny` auf `.git/**`.** `bypassPermissions` schaltet laut Dokumentation
  ausgerechnet den Schutz der „protected paths" wie `.git` und `.claude` ab. Ohne
  diese Regeln käme man mit dem Werkzeug `Write` an der Historie vorbei, ohne je
  ein `git`-Kommando aufzurufen.
- **Eine kurze `ask`-Liste für das Unumkehrbare ausserhalb von git.** Sonst wäre
  git die einzige Ausnahme, und `rm -rf` im Nachbarordner liefe durch.

## Warum es für git nur EINE Schicht gibt — und wie die zweite verschwand

Hier stand eine ganze Zeit ein zweiter Mechanismus: ein eigener
`PreToolUse`-Hook, 133 Zeilen, der die rohe Kommandozeile nach git-Verben
durchsuchte und mit Exitcode 2 abbrach. Die Begründung war plausibel und war
falsch.

Die Annahme: Muster sehen ein Kommando nur von vorn, also entgehen der
`ask`-Liste `cd repo && git push`, `x=$(git push)` und `bash -c "git push"`. Die
Dokumentation ist an dem Punkt zweideutig — sie sagt, Claude Code trenne an `&&`,
`;` und `|`, und „a rule must match each subcommand independently". Das klärt die
`allow`-Richtung, nicht die `ask`-Richtung.

Messen war billiger als bauen, und es brauchte **keine Sandbox**: eine
`deny`-Regel, die ohnehin da war, genügt. Mit `deny: ["Bash(env)"]`:

```bash
cd /tmp && env       # blockiert  -> Regeln greifen pro Segment
echo "$(env)"        # blockiert  -> Regeln greifen in Substitution
```

Drei der vier vermuteten Lücken existierten nicht. Für die eine echte —
`bash -c "git push"`, also ein Kommando in einer Zeichenkette — braucht es keinen
Hook, sondern drei Musterzeilen:

```
Bash(bash -c *)  Bash(sh -c *)  Bash(zsh -c *)
```

Und die sind sogar treffender: nicht „git in einer Zeichenkette" ist verdächtig,
sondern überhaupt ein Kommando in eine Shell zu verpacken.

Was mit dem Hook bewusst aufgegeben wurde: **Shell-Umleitungen nach `.git/`**. Die
`deny`-Regeln greifen nur für die Werkzeuge `Edit` und `Write`, nicht für
`echo x > .git/config`. Abwägung: wer die Historie zerstören will, kann
`rm -rf .git`, und das fängt `Bash(rm -rf *)`. 133 Zeilen Regex für den Rest sind
zu teuer — zumal genau diese Regex einen Fehler hatte, und zwar in dem einen Fall,
den sie als einzige abdecken sollte.

> 🎯 Zwei Lehren, und die zweite trägt weiter.
>
> **Eine Sperre, die man nicht gemessen hat, ist eine Vermutung.**
>
> Und: **Messen löscht öfter Code als es welchen schreibt.** Der billigste Weg zu
> einem einfacheren System ist herauszufinden, was die Plattform schon selbst tut.

Einschränkung, damit hier nichts überverkauft wird: gemessen wurde mit
`deny`-Regeln, nicht mit `ask`. Laut Dokumentation benutzen beide denselben
Abgleich und dieselbe Segmenttrennung — es ist derselbe Matcher, aber die Messung
deckt die eine Hälfte davon ab.

Die Muster heissen übrigens `Bash(git *VERB*)` und nicht `Bash(git VERB *)`, weil
sonst jede globale Option davor durchrutscht (`git -C unterordner commit`). Der
Preis ist ein gelegentlicher Fehlalarm.

### Und die ehrliche Grenze

Mit einem vollen `gh`-Token in der Sandbox ist diese Konstruktion eine **Bremse
gegen Versehen, keine Grenze**. Ein Skript, das intern pusht, git über eine
Bibliothek, ein umbenanntes Binary — daran kommt keine Musterliste heran. Wer eine
echte Grenze will, nimmt sie dem **Token** weg statt dem Kommando: ein
feingranularer PAT mit Leserechten lässt `push` strukturell scheitern. Der Preis
sind keine PRs aus der Sandbox.

Diese Entscheidung wurde bewusst zugunsten der Bequemlichkeit getroffen. Sie
gehört benannt, nicht versteckt.

## Der Rückkanal: warum eine Datei und nicht das Netz

Eine Benachrichtigung aus dem Container ist nicht trivial, und die
Schwestervarianten geben sie deshalb auf — sie **schalten** die Notification- und
Stop-Hooks des Hosts **ab**, weil die `osascript` aufrufen.

Die Lage: Claude läuft in einem Linux-Container und kann keine macOS-Meldung
erzeugen. Er kann den Mac auch nicht anrufen — es gibt keine konfigurierte Route,
und die Netz-Policy ist Deny-by-default. Drei Wege wären denkbar:

| Weg | Warum nicht / warum doch |
| --- | --- |
| Push-Dienst (`ntfy.sh`) | erreicht auch das Handy, hängt aber an einem Fremddienst und braucht eine Netz-Freigabe |
| Route zum Host | müsste erst geschaffen und freigegeben werden — genau die Wand, die wir bauen, bekäme ein Loch |
| **gemeinsame Datei** | sbx hängt Host-Verzeichnisse ohnehin ein; kein Netz, kein Dienst, kein Loch |

Also die Datei. Ein read-write eingehängter Ereignisordner, ein Hook im Container
schreibt, ein Wächter auf dem Host liest.

### Die Vertrauensrichtung ist die eigentliche Entscheidung

Ein read-write Mount ist ein Kanal **aus** der Sandbox **auf** den Host. Alles
darin ist vom Agenten beeinflussbar — Dateinamen wie Inhalte. Gäbe der Wächter
Text daraus an `osascript` weiter, wäre das AppleScript-Injection: Codeausführung
auf dem Mac, vorbei an der ganzen Sandbox. Ein bösartiger Dateiname genügte.

Daraus folgt das absichtlich armselige Format: **ein Wort aus einer festen Liste
und eine Zahl**, durch einen Tabulator getrennt. Kein Freitext, kein Projektname,
kein JSON. Der Wächter prüft beides vollständig, formuliert die Meldung selbst,
nimmt den Projektnamen aus dem gegen ein Muster geprüften Dateinamen und übergibt
`terminal-notifier` **Argumente**, nie eine Shell-Zeile.

Das wurde durchgespielt: manipulierte Dauer wird zu `0` entschärft, manipuliertes
Ereigniswort komplett verworfen, nichts ausgeführt.

Eine kleinere Konsequenz derselben Richtung: Die **Leseposition** des Wächters
liegt ausserhalb des Ereignisordners — dort darf der Container schreiben und
könnte sie sonst verstellen.

Was der Hook zur Laufzeit noch braucht — Ereignisordner, Sandbox-Name, Schwelle —
bekommt er als **Argumente** aus der abgeleiteten `settings.json`. Im Image
könnten diese Werte nicht stehen: der Ordner ist ein Host-Pfad, der Name entsteht
erst pro Projekt. Es gab dafür einmal eine eigene Datei in der Sandbox, die der
Wrapper hineinschrieb und der Hook einlas. Sie war ein Umweg — die Werte sind
genau an der Stelle bekannt, an der die `settings.json` entsteht — und ein
zusätzlicher Fehlerfall: „Datei fehlt, keine Meldung, keine Ursache".

### Die Schwelle ist Teil der Zuverlässigkeit

`Stop` feuert nach jeder Antwort. Ungefiltert wären das bei einem längeren Dialog
dutzende Meldungen — und dann schaltet man sie ab. Eine Benachrichtigung, die
abgeschaltet wird, ist unzuverlässig, egal wie gut sie funktioniert. Deshalb:
`Notification` immer (da wartet Claude wirklich), `Stop` erst ab einer
konfigurierbaren Dauer. `SessionEnd` stand hier auch einmal — eine Meldung dafür,
dass man gerade selbst Claude beendet hat, braucht niemand.

Dass eine `ask`-Rückfrage dabei den `Notification`-Hook auslöst, ist kein Zufall,
aber auch nicht extra gebaut: die git-Bremse aus Kapitel 5 und der Rückkanal aus
Kapitel 6 greifen von sich aus ineinander. Du erfährst „will pushen, wartet auf
dich", ohne dass dafür eine Zeile Code existiert.

## Hooks kommen aus dem Image, nicht vom Host

Ein Hook, der nur `jq` und die Hook-Eingabe von stdin benutzt, läuft überall. Ein
Hook, der `terminal-notifier` aufruft, läuft nur auf einem Mac.

Deshalb ist `HOOK_UEBERNEHMEN` eine **Liste und keine Heuristik**: übernommen
werden genau die Ereignisse, von denen wir wissen, dass sie portabel sind. Die
vier Ereignisse des Rückkanals besetzt sbx-claude selbst, mit Skripten aus dem
Image — nicht aus einem Mount, weil ein Hook auch dann funktionieren muss, wenn
vom Host gerade nichts erreichbar ist.

Aus demselben Grund wird die `settings.json` **abgeleitet und nie gemountet**:
übernommen werden nur vier Schlüssel, die nichts über den Host verraten, plus die
portablen Hooks. Der `sandbox`-Block des Hosts fliegt aktiv heraus — seine Pfade
(`/Users/du/**`, `denyRead: ["~/"]`) zeigen im Container ins Leere und sähen dabei
aus, als schützten sie etwas. Der sbx-Container **ist** hier die Sandbox.

## Skills: die eine Entscheidung gegen die Empfehlung

sbx hat für Skills ein eigenes Kommando, `sbx skills import`. Es wird hier
benutzt — auf ausdrücklichen Wunsch, und gegen die Empfehlung, die beim Entwurf
ausgesprochen wurde. Der Preis gehört deshalb besonders klar hierher:

**Erstens** hängt der Store am Feature-Flag `feature.shareSkills`, und das ist
eine **maschinenweite sbx-Einstellung**, keine v3-Einstellung. Ist sie an, hängt
*jede* Sandbox auf diesem Rechner den Store ein — auch fremde, auch eine
`solobox`, deren eigener Kopierschritt dann in den Store schreibt statt in einen
Sandbox-Ordner. Die Regel aus der `CLAUDE.md` des Repos („änderst du eine
Variante, ist die andere nicht betroffen") hält an dieser Stelle **nicht mehr** —
nicht durch v3-Code, sondern durch eine globale Einstellung.

**Zweitens** ist der Store **read-write und von allen geteilt**. Bei einer Box pro
Projekt kann der Agent in Projekt A einen Skill verändern, den Projekt B morgen
ausführt. Das ist genau die Grenze, die diese Variante ziehen soll.

Drei Sicherungen mildern das, ohne es aufzuheben: `doctor` benennt den
Flag-Zustand, `up` schaltet das Flag **niemals still** um (es fragt einmal), und
`ISOLATE_SKILLS=1` setzt `--no-share-skills` für Projekte, deren Code man nicht
kennt.

`--no-share-skills` ist die **einzige** Ausnahme von der Regel, nur stabile
sbx-Flags zu benutzen: sie steht nicht in `sbx create --help` und gehört zum
EXPERIMENTAL-Kommando `sbx skills`. Deshalb steht sie nicht im Standardweg, und
`supports_no_share_skills()` prüft vorher, ob die installierte Version sie
überhaupt kennt.

## Netzregeln nur pro Sandbox

Ohne `--sandbox` gilt eine Regel global für alle Sandboxes. Auf derselben Maschine
kann ein fremdes sbx-Setup laufen, das nicht verändert werden darf. Also
ausnahmslos `--sandbox`.

Bei einer Box pro Projekt wird eine **projektlokale** Liste erstmals sinnvoll —
und gleichzeitig gefährlich: `.sbx-claude-hosts` liegt im Repo, also dort, wo der
Agent schreiben darf. Er könnte sich selbst Hosts freigeben und damit die einzige
Grenze aufziehen, die gegen Exfiltration wirkt. Deshalb wird die Liste beim `up`
**angezeigt und einmal bestätigt**, und die Bestätigung ausserhalb des Projekts
gemerkt. Das ist der Unterschied zwischen bequem und wirksam.

## Beobachtete Tatsachen statt Merkzettel — mit einer begründeten Ausnahme

Der Wrapper vertraut keiner Datei auf dem Host, wenn er eine Tatsache beobachten
kann. Der Stempel im Image (als Label **und** als Datei in der Box) ist der Kern
davon: eine Merkdatei kann fehlen, verloren gehen oder auf einem anderen Rechner
nie existiert haben. `/etc/sbx-claude-stamp` in einer laufenden Box kann nicht
lügen.

Und dann kommt die Sandbox-pro-Projekt-Aufteilung und macht aus dem Prinzip ein
Problem. Der Stempel in der Box ist nur lesbar, wenn die Box **läuft** —
`sbx exec` würde eine gestoppte sonst erst starten, und dann bootet ein blosses
`status` acht Container. Bei **einer** Sandbox, die meist läuft, ist das eine
Randnotiz. Bei zehn, die meist gestoppt sind, ist „kann ich nicht sagen" die
Regelantwort. Genau das stand hier in einer früheren Fassung: `check` meldete
freundlich „übersprungen", und `up` lief danach mit einem veralteten Image weiter.

Ein Prinzip, das im häufigsten Fall keine Auskunft gibt, ist kein Prinzip, sondern
eine Pose. Deshalb notiert `provision` den Dockerfile-Hash beim Anlegen zusätzlich
auf dem Host, und `sandbox_stand()` schichtet die Quellen:

| Lage | Quelle | Belastbarkeit |
| --- | --- | --- |
| Box läuft | Stempel in der Box | beobachtet, kann nicht lügen |
| Box gestoppt, Notiz da | Notiz vom Anlegen | kann fehlen oder verstellt sein |
| Box gestoppt, keine Notiz | — | „Stand unbekannt", ehrlich gesagt |

Die Beobachtung gewinnt immer, wenn es sie gibt. Und — das ist der Teil, der das
Prinzip retten muss — **die Ausgabe sagt dazu, woher die Auskunft kommt**:
„Stempel in der Box gelesen" gegen „laut Notiz vom Anlegen". Eine Prüfung, die
nicht verrät, wie sicher sie ist, verschiebt das Problem nur.

Nebenbei löste das eine Doppelung auf: derselbe Vergleich stand vorher dreimal im
Skript, in `check`, `status` und `update`, mit drei leicht verschiedenen
Formulierungen. Und die Notiz ersetzte eine, die geschrieben und **nie gelesen**
wurde — die Template-ID pro Sandbox. Ein Merkzettel ohne Leser ist kein Zustand,
sondern Ballast.

Übrige Merkdateien, jede mit einem Grund: die Pfad-Zuordnung für die
Namenskollision (es gibt keine beobachtbare Tatsache darüber, welcher Name zu
welchem Pfad gehört) und die bestätigten projektlokalen Hosts (eine Zustimmung ist
per Definition keine Beobachtung).

Und `gewuenschte_mounts()` ist die **einzige** Quelle der Mount-Liste. `provision`
legt danach an, `pruefe_stand` vergleicht dagegen. Eine zweite Liste würde den
Drift-Check brechen — er meldete dann ewig Unterschiede oder übersähe echte.

## Safe Chain als Shims, nicht als Shell-Funktionen

Eine Shell-Funktion existiert nur **in** der Shell. Jeder Aufruf, der `npm` als
Programm startet, geht daran vorbei: `timeout npm …`, `env npm …`,
`xargs … npm`, `sbx exec … npm`. Nachgemessen ging das offizielle Testpaket
`safe-chain-test` mit vorangestelltem `timeout` durch, während derselbe Befehl
ohne es blockiert wurde. Das ist eine Lücke, keine Kosmetik. Also echte Dateien im
PATH.

## pnpm nicht über corepack

`corepack prepare --activate` legt seine Aktivierung im Cache des Bau-Users ab.
Zur Laufzeit läuft `agent`, kommt dort nicht heran und lädt still eine andere
Version nach — mit sichtbarer Download-Meldung, aber ohne Fehler. `npm install -g`
landet in `/usr/local/lib/node_modules` und gilt fest.

## Das Dockerfile ist voll ausgestattet, und das ist kein Zufall

Die intuitive Wahl wäre „schlank bauen, später nachlegen". Für **diese** Variante
ist sie falsch: Ein neues Template erreicht bestehende Sandboxes nicht. Nachlegen
heisst also Image neu bauen **und pro Projekt** löschen, neu anlegen, neu anmelden.
Bei zehn Projekten ist das ein Nachmittag.

In `solobox`, mit genau einer Box, kostet Nachlegen fast nichts. Dieselbe
Überlegung führt hier zum Gegenteil. Da der einzige schwere Posten Chromium ist
(~1,5–2 GB; ein zusätzlicher Python ~150 MB, `poetry`/`ruff` wenige zehn MB), ist
„Vollausstattung" fast dasselbe wie „schlank plus Chromium".

## Was diese Variante aufgibt

| | Preis |
| --- | --- |
| Anmeldung | einmal `/login` pro Projekt — der Mac-Login liegt im Keychain, es gibt keine Datei zum Einhängen |
| Nachrüsten | ein neues Image erreicht bestehende Boxen nicht: N-mal `rm` + `up` + `/login` |
| Plattenplatz | ein Container pro Projekt, plus ein grosses gemeinsames Image |
| Skill-Trennung | der geteilte Store durchbricht die Projekt-Trennung (siehe oben) |
| git-Sperre | mit vollem Token eine Bremse, keine Grenze |
| Host-Prozess | der Wächter muss laufen, sonst kommt keine Meldung an |

Wer diese Preise nicht zahlen will, ist mit `v2/` (eine Box für alles) oder
`v1/` (eine Box pro Profil) besser bedient. Die drei Varianten teilen nichts
ausser den `sbx`-Begriffen und können nebeneinander laufen.

## Was bewusst *nicht* gemacht wurde

| Idee | Warum nicht |
| --- | --- |
| `--clone` statt Bind-Mount | Host-Dateien wären unzerstörbar, aber jeder Blick auf `git status` und jede Übernahme ein Fetch. Eine Ebene zu viel. |
| Credentials auf dem Host cachen | spart das `/login` pro Projekt, legt aber ein lebendes OAuth-Token als Klartextdatei neben den Keychain — und paralleles Token-Refresh kann eine Box abmelden. |
| `sbx mcp add --command` | startet den Server als Prozess auf dem **Host**, aussen an der Sandbox vorbei. Ein Loch in genau der Wand, die hier gebaut wird. |
| `--static-mcp` beim Anlegen | eine zweite Ein-Weg-Entscheidung neben den Mounts. `sbx mcp load` bleibt flexibel. |
| `~/.ssh` einhängen | der private Schlüssel öffnet meist mehr als GitHub, und `:ro` hilft nicht: Lesen genügt zum Benutzen. |
| `~/.claude.json` mounten | dort stehen MCP-Einträge und Sitzungszustand in einer Datei. |
| `sbx kit` als Hauptweg | `sbx kit --help` sagt wörtlich „EXPERIMENTAL: this command may change or be removed". |
| Eine Heuristik für portable Hooks | „enthält kein osascript" ist keine Portabilitätsprüfung. Eine Liste ist ehrlicher. |
