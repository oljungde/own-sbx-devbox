# Kapitel 5 — Berechtigungen und git

Das Ziel dieses Kapitels ist ungewöhnlich: **nirgends gefragt werden — ausser bei
git.** Das klingt nach einem Widerspruch zu jedem Sicherheitsratschlag, ist aber
genau das, was ein Bind-Mount-Setup braucht. Warum, und wie es geht.

## Warum nicht einfach bypass für alles

Der Workspace ist ein **echter Bind-Mount**. Der Container schützt dein
**System**, nicht dein **Repo**:

```bash
rm -rf src/            # trifft echte Dateien auf dem Mac
git reset --hard       # löscht echte, nicht committete Arbeit
git push --force       # trifft ein echtes Remote
```

Die Netz-Policy aus Kapitel 3 verhindert, dass Daten **hinausgehen**. Gegen
**Zerstörung** hilft sie nicht. `bypassPermissions` allein nimmt dir also den
letzten Halt vor genau diesen drei Zeilen.

## Warum nicht einfach für alles fragen

`acceptEdits` fragt bei jedem Bash-Kommando, `default` zusätzlich bei jedem
Datei-Edit. In der Praxis klickt man das nach zwei Sitzungen weg — und stellt
dann meist gleich auf bypass um. Eine Rückfrage, die man reflexhaft bestätigt,
schützt nichts. Sie ist schlechter als keine, weil sie Sicherheit vortäuscht.

> 🎯 Rückfragen sind eine begrenzte Ressource. Man gibt sie dort aus, wo etwas
> unumkehrbar ist — nicht dort, wo `git` es ohnehin zurückholt.

## Die Lösung: `ask` gilt auch im bypass-Modus

Neben `allow` und `deny` gibt es eine dritte Liste, und die Dokumentation ist an
dem Punkt ausdrücklich:

> „These controls apply in every mode, including `bypassPermissions`: deny rules
> and explicit ask rules"

und

> „Rules are evaluated in order: deny, then ask, then allow."

Damit ist genau unser Wunsch baubar:

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "ask": ["Bash(git *commit*)", "Bash(git *push*)", "..."],
    "deny": ["Edit(.git/**)", "Write(.git/**)"]
  }
}
```

Lesende git-Verben (`status`, `log`, `diff`, `show`, `blame`) stehen **nicht** in
der Liste. Sie fassen nichts an, und Claude braucht sie ständig zur Orientierung.

## ⚠️ Drei Details, an denen es sonst still versagt

**1. `deny` auf `.git/**` ist Pflicht, nicht Kür.** Die Dokumentation warnt:
`bypassPermissions` schaltet ausgerechnet den Schutz der „protected paths" wie
`.git` und `.claude` mit ab. Ohne diese Regeln könnte Claude mit dem Werkzeug
`Write` direkt in `.git/` schreiben, ohne je ein `git`-Kommando aufzurufen.

**2. Das Muster muss `git *VERB*` heissen, nicht `git VERB *`.** Sonst rutscht
jede globale Option davor durch:

```bash
git commit -m "x"          # Bash(git commit *) trifft
git -C unterordner commit  # Bash(git commit *) trifft NICHT
git -C unterordner commit  # Bash(git *commit*) trifft
```

Der Preis ist ein gelegentlicher Fehlalarm — `git log --grep=push` fragt dann
auch. Ein Klick gegen einen übersehenen Push: leichte Entscheidung.

**3. Die Datei muss aufgeräumt werden.** Das Basis-Image bringt in seiner
`settings.json` eigene Werte für `defaultMode` und
`bypassPermissionsModeAccepted` mit. Wer nur `permissions.defaultMode` setzt, hat
eine Datei, die zwei Dinge gleichzeitig sagt.

## ⚠️ Was Muster sehen — und was nicht. Nachgemessen.

Hier stand in der ersten Fassung dieses Kapitels ein zweiter Mechanismus: ein
eigener `PreToolUse`-Hook mit 133 Zeilen, der die rohe Kommandozeile nach
git-Verben durchsuchte. Er ist wieder verschwunden, und **wie** er verschwand ist
lehrreicher als er selbst.

Die Annahme war: Muster sehen ein Kommando nur von vorn, also entgeht ihnen
`cd repo && git push`. Die Dokumentation ist an dem Punkt zweideutig — sie sagt,
Claude Code trenne an `&&`, `;` und `|`, und „a rule must match each subcommand
independently". Das klärt die `allow`-Richtung, nicht die `ask`-Richtung.

Statt es zu vermuten, kann man es messen — und zwar **ohne Sandbox**, in einer
ganz normalen Claude-Sitzung. Man braucht nur eine `deny`-Regel, die man ohnehin
hat. Mit `deny: ["Bash(env)"]` in der `settings.json`:

```bash
cd /tmp && env | head -2         # steht "env" an zweiter Stelle: greift die Regel?
echo "$(env | wc -l) zeilen"     # und in einer Command-Substitution?
```

Beides wurde **blockiert**. Ergebnis:

| Form | Annahme | Messung |
| --- | --- | --- |
| `cd repo && git push` | Muster sieht es nicht | **Regel greift** (Segment 2) |
| `x=$(git push)` | Muster sieht es nicht | **Regel greift** |
| `(git commit -m "x")` | Muster sieht es nicht | **Regel greift** (Subshell) |
| `timeout 60 git push` | Hülle wird abgeschält | Regel greift |
| `bash -c "git push"` | Muster sieht es nicht | Muster sieht es wirklich nicht |
| `npm run release` | nicht erkennbar | nicht erkennbar |

Von vier vermuteten Lücken waren drei keine. Für die eine echte braucht es keinen
Hook, sondern drei Zeilen Konfiguration:

```bash
EXTRA_ASK+=( "Bash(bash -c *)" "Bash(sh -c *)" "Bash(zsh -c *)" )
```

Und das ist sogar die bessere Regel. Nicht „git in einer Zeichenkette" ist
verdächtig, sondern **überhaupt ein Kommando in eine Shell zu verpacken**.

> 🎯 Zwei Lehren, und die zweite ist die wichtigere.
>
> Die erste: **eine Sperre, die man nicht gemessen hat, ist eine Vermutung.** Der
> gelöschte Hook hatte prompt einen Fehler in genau dem Fall, den er als einziger
> abdecken sollte — seine Wortgrenze verlangte ein Leerzeichen, und nach
> `bash -c "git push"` stand ein Anführungszeichen.
>
> Die zweite: **Messen löscht öfter Code als es welchen schreibt.** Der billigste
> Weg zu einem einfacheren System ist herauszufinden, was die Plattform schon
> selbst tut.

Einschränkung, damit hier nichts überverkauft wird: gemessen wurde mit
`deny`-Regeln, nicht mit `ask`. Laut Dokumentation benutzen beide denselben
Abgleich und dieselbe Segmenttrennung — es ist derselbe Matcher, aber die Messung
deckt die eine Hälfte davon ab.

Bewusst aufgegeben mit dem Hook: **Shell-Umleitungen nach `.git/`**. Die
`deny`-Regeln greifen nur für die Werkzeuge `Edit` und `Write`, nicht für
`echo x > .git/config`. Die Einschätzung dahinter: wer die Historie zerstören
will, kann `rm -rf .git` — und das fängt `Bash(rm -rf *)`. Für den Rest wären 133
Zeilen Regex zu teuer gewesen.

## Was das alles nicht schafft

Mit einem vollen `gh`-Token in der Sandbox ist diese Konstruktion eine **Bremse
gegen Versehen, keine Grenze**. Wer eine Shell hat, kommt an einer Musterliste
vorbei, wenn er will: ein Skript, das intern pusht, git über eine Bibliothek, ein
umbenanntes Binary, `python -c "subprocess…"`.

Wer eine echte Grenze will, nimmt sie dem Token weg statt dem Kommando: ein
feingranularer PAT mit Leserechten. Dann scheitert `push` strukturell, und die
Rückfragen sind nur noch Komfort. Der Preis: keine PRs aus der Sandbox.

## Und das Unumkehrbare ausserhalb von git

bypass macht sonst **nur** git zur Ausnahme. Deshalb kommt eine kurze zweite
`ask`-Liste dazu:

```
Bash(rm -rf *)  Bash(rm -fr *)  Bash(sudo *)  Bash(chmod -R *)
Bash(chown -R *)  Bash(dd *)  Bash(sh)  Bash(shutdown *)  Bash(reboot *)
Bash(bash -c *)  Bash(sh -c *)  Bash(zsh -c *)
```

`Bash(sh)` ist kein Tippfehler: Bei `curl … | sh` trennt Claude Code an der
Pipe, `sh` ist dann ein eigenes Segment — und genau das wollen wir sehen. Die
drei `-c`-Muster sind der Ersatz für den gelöschten Hook.

Eingebaut gibt es ohnehin eine Notbremse für `rm -rf /` und `rm -rf ~`, die auch
im bypass-Modus fragt. Auf mehr sollte man sich nicht verlassen.

## Was NICHT mitkommt

Deine Host-`settings.json` hat einen `sandbox`-Block mit Pfaden wie
`/Users/du/**` und `denyRead: ["~/"]`. Der wird **nicht** übernommen: im
Container ist `$HOME` gleich `/home/agent`, die Regeln zeigten ins Leere und
sähen dabei aus, als schützten sie etwas. Der sbx-Container **ist** hier die
Sandbox.

Folge, und die gehört beim ersten Lauf nachgemessen: ohne diesen Block bekommst
du bei Bash-Kommandos tatsächlich Rückfragen, statt dass
`autoAllowBashIfSandboxed` sie stillschweigend durchlässt.

Weiter mit [Kapitel 6](06-benachrichtigung.md).
