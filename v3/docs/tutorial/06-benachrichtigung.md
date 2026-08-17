# Kapitel 6 — Benachrichtigung

Du gehst Kaffee holen, Claude arbeitet. Woher weisst du, dass er fertig ist?

Dieses Kapitel ist der Grund, warum es diese dritte Variante gibt. Die beiden
anderen **schalten** die Desktop-Benachrichtigung **ab**. Hier baust sie so, dass
sie funktioniert.

## Warum der naheliegende Weg nicht geht

Auf dem Host hast du vermutlich schon einen `Stop`-Hook, der `terminal-notifier`
oder `osascript` aufruft. In der Sandbox scheitert er, und zwar unangenehm:

```
osascript: command not found
```

Drei Gründe, hintereinander:

1. Claude läuft in einem **Linux-Container**. Eine macOS-Meldung braucht
   macOS-APIs. Die gibt es dort nicht.
2. Der Container kann den Mac auch nicht **anrufen**: es gibt keine
   konfigurierte Route dorthin, und die Netz-Policy ist Deny-by-default.
3. Läuft der Hook mit `set -e` — und die typische `notify.sh` tut das —, endet er
   nicht still, sondern mit einem Fehler. Nach **jeder** Antwort.

Deshalb übernimmt `sbx-claude` die Hook-Ereignisse `Notification`, `Stop` und
`UserPromptSubmit` **nicht** vom Host, sondern besetzt sie mit einem eigenen
Skript aus dem Image.

## Der Weg, den es gibt: eine Datei

sbx hängt Host-Verzeichnisse read-write und unter **demselben absoluten Pfad**
ein. Eine Zeile, die der Container schreibt, ist im selben Moment eine echte
Datei auf dem Mac. Das ist der Kanal.

```
  Container                          Host
  ---------                          ----
  Claude wird fertig
        |
  sbx-claude-notify stop
        |  schreibt eine Zeile
        v
  ~/.local/state/sbx-claude/events/sbx-claude-api.ereignisse
                                    |  liest
                                    v
                             watch.sh (der Wächter)
                                    |
                             terminal-notifier
                                    v
                             Meldung auf dem Bildschirm
```

Zusätzlich schreibt der Hook ein `\a` nach `/dev/tty` — die Terminal-Glocke, die
den Tab sofort markiert, noch bevor der Wächter reagiert.

### Woher der Hook den Pfad kennt

Der Ereignisordner ist ein **Host**-Pfad. Im Image kann er also nicht stehen, und
der Sandbox-Name entsteht sowieso erst pro Projekt. Beides bekommt der Hook als
**Argumente**, direkt aus der abgeleiteten `settings.json`:

```json
"Stop": [{"hooks": [{"type": "command", "command":
  "/usr/local/bin/sbx-claude-notify stop '/Users/du/.local/state/sbx-claude/events' sbx-claude-api 60"
}]}]
```

> 🎯 Hier stand einmal eine eigene Datei `~/.sbx-claude-env` in der Sandbox, die
> der Wrapper hineinschrieb und der Hook einlas. Sie war ein Umweg: die Werte sind
> genau an der Stelle bekannt, an der die `settings.json` entsteht. Und sie war
> ein zusätzlicher Fehlerfall — „Datei fehlt, keine Meldung, keine Ursache". Zwei
> bewegliche Teile weniger, gleiche Funktion.
>
> Der Pfad steht in einfachen Anführungszeichen, weil er in einer Shell-Zeile
> landet. Ohne Klammerung bräche ein Leerzeichen im Pfad den Aufruf.

## ⚠️ Das Format ist absichtlich armselig

Eine Zeile besteht aus **einem Wort und einer Zahl**, getrennt durch einen
Tabulator:

```
fertig	142
wartet	0
```

Kein Freitext, kein Projektname, kein JSON. Der Grund ist keine Sparsamkeit,
sondern die Vertrauensrichtung:

> Der Ereignisordner ist ein Kanal **aus** der Sandbox **auf** den Host. Alles
> darin ist vom Agenten beeinflussbar — Dateinamen wie Inhalte. Würde der
> Wächter Text daraus an `osascript` weitergeben, wäre das
> **AppleScript-Injection**: Codeausführung auf dem Mac, vorbei an der ganzen
> Sandbox. Ein bösartiger Dateiname genügte.

Ein Wort aus einer festen Liste und eine Zahl kann der Wächter dagegen
**vollständig prüfen**. Den Text der Meldung formuliert er selbst, und den
Projektnamen nimmt er aus dem Dateinamen, den er gegen ein Muster geprüft hat.

### Nachgemessen

Der Angriff wurde beim Bauen dieser Fassung durchgespielt. Präparierte
Ereignisdatei:

```
fertig	$(touch /tmp/BEWEIS-ZAHL)
"; touch /tmp/BEWEIS-WORT; "	7
fertig	120
```

Ergebnis:

| Zeile | Was passierte |
| --- | --- |
| manipulierte **Dauer** | zu `0` entschärft, Meldung normal ausgegeben |
| manipuliertes **Wort** | komplett verworfen, keine Meldung |
| reguläre Zeile | Meldung wie erwartet |

Und die Kontrollfrage: keine `BEWEIS-*`-Datei entstand. Nichts wurde ausgeführt.

Ausserdem läuft `terminal-notifier` mit **Argumenten**, nie über eine
Shell-Zeile:

```
MELDUNG: [-title] [Claude — fertig] [-subtitle] [api] [-message] [Antwort nach 120 Sekunden abgeschlossen.] [-sound] [Glass]
```

## ⚠️ Die Schwelle, ohne die es nichts wert ist

`Stop` feuert nach **jeder** Antwort. Bei einem Dialog mit dreissig Runden wären
das dreissig Meldungen — und dann schaltet man sie ab. Damit wäre die zuverlässige
Benachrichtigung wertlos geworden, weil sie zu zuverlässig war.

Also:

| Ereignis | Wann gemeldet wird |
| --- | --- |
| `Notification` | **immer** — hier wartet Claude wirklich auf dich, auch bei jeder git-Rückfrage aus Kapitel 5 |
| `Stop` | nur wenn die Runde **≥ `NOTIFY_SCHWELLE`** (Standard 60 s) gedauert hat |
| Glocke | immer |

Die Dauer misst der Hook über eine Startmarke, die `UserPromptSubmit` setzt.

> 🎯 `SessionEnd` stand hier auch einmal drin und ist wieder verschwunden. Eine
> Meldung dafür, dass du gerade selbst Claude beendet hast, braucht niemand — du
> warst ja dabei. Drei Hooks statt vier.

> 🎯 Die Marke trägt die **Sitzungskennung** im Dateinamen. In einer Sandbox
> können mehrere Claude-Sitzungen gleichzeitig laufen (ein zweites Terminal, ein
> `sbx-claude shell` daneben). Mit einer festen Marke überschriebe eine Sitzung
> die Startzeit der anderen, und die gemeldeten Dauern wären Zufallszahlen.

Und noch eine Kleinigkeit, die gemessen wurde: Die Glocke braucht Klammern.

```sh
printf '\a' > /dev/tty 2>/dev/null      # falsch
{ printf '\a' > /dev/tty; } 2>/dev/null # richtig
```

Ohne Terminal meldet die **Shell** den Öffnungsfehler, nicht `printf` — und die
Umleitung galt nur für `printf`. Ergebnis war ein
`notify.sh: line 74: /dev/tty: Device not configured` in der Ausgabe.

## Der Wächter läuft auf dem Host

Er ist der einzige Teil von sbx-claude, der dauerhaft auf dem Mac laufen muss.
Läuft er nicht, kommt keine Meldung an — deshalb prüft `doctor` ihn.

Zum Zuschauen:

```bash
sbx-claude watch
```

Dauerhaft, als LaunchAgent, der die Anmeldung überlebt:

```bash
sbx-claude install --watcher
launchctl list | grep sbx-claude
tail -f ~/.local/state/sbx-claude/watch.log
```

Er beobachtet den **ganzen Ordner**, also alle Projekt-Sandboxes gleichzeitig.
Eine Instanz genügt, egal wie viele Boxen laufen.

Zwei Kleinigkeiten in seiner Bauart, die man sonst nachbaut und sich wundert:

- Die **Leseposition** wird ausserhalb des Ereignisordners gemerkt
  (`~/.local/state/sbx-claude/watch-offsets/`). Im Ereignisordner darf der
  Container schreiben — dort könnte er unsere Position verstellen.
- Beim Start wird die aktuelle Länge einmal notiert, ohne zu melden. Sonst
  bekämst du beim Anmelden die ganze Historie auf den Bildschirm.

## Probe

```bash
sbx-claude watch          # in Tab 2 laufen lassen
sbx-claude up             # in Tab 1, dann Claude etwas Langes fragen
```

Nach mehr als 60 Sekunden erscheint die Meldung, und der Tab von Tab 1 markiert
sich. Nichts passiert? Dann in dieser Reihenfolge nachsehen:

```bash
ls -la ~/.local/state/sbx-claude/events/          # kommt überhaupt etwas an?
sbx exec sbx-claude-api cat ~/.claude/settings.json | grep notify   # stimmt der Pfad im Hook?
sbx-claude doctor                                  # läuft der Wächter?
```

Weiter mit [Kapitel 7](07-mcp.md).
