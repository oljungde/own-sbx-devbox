#!/bin/sh
# =============================================================================
# sbx-claude — Benachrichtigungs-Hook, läuft IN der Sandbox
#
# Warum dieses Skript überhaupt existiert:
#
#   Claude läuft in einem Linux-Container. Eine macOS-Meldung braucht macOS
#   (`osascript`, `terminal-notifier`) — beides gibt es hier nicht. Und der
#   Container kann den Mac auch nicht anrufen: es gibt keine Route dorthin, und
#   die Netz-Policy ist Deny-by-default.
#
#   Was es gibt, ist ein gemeinsamer Ordner. sbx hängt Host-Verzeichnisse unter
#   demselben absoluten Pfad ein, also ist eine Zeile, die wir hier schreiben,
#   im selben Moment eine echte Datei auf dem Mac. Der Wächter auf dem Host
#   (v3/hooks/watch.sh) liest sie und macht die Meldung daraus.
#
# ⚠️  Das Format ist bewusst armselig: EIN Wort und EINE Zahl, getrennt durch
#     einen Tabulator. Kein Freitext, keine Projektnamen, kein JSON.
#
#     Grund: Dieser Ordner ist ein Kanal aus der Sandbox auf den Host. Alles,
#     was hier hineingeschrieben wird, ist vom Agenten beeinflussbar. Würde der
#     Wächter Text daraus an `osascript` weitergeben, wäre das
#     AppleScript-Injection — also Codeausführung auf dem Mac, vorbei an der
#     ganzen Sandbox. Ein Wort aus einer festen Liste und eine Zahl kann der
#     Wächter dagegen vollständig prüfen.
#
# Aufruf (aus der abgeleiteten settings.json):
#   sbx-claude-notify start|stop|wartet EREIGNISORDNER SANDBOX SCHWELLE
#
# Die drei Werte kommen als ARGUMENTE und nicht aus einer Datei in der Sandbox.
# Sie könnten auch nicht im Image stehen: der Ereignisordner ist ein Host-Pfad,
# und der Sandbox-Name entsteht erst pro Projekt. Der Wrapper kennt beides
# genau dann, wenn er die settings.json schreibt — also schreibt er sie dort
# gleich mit hinein. Eine eigene Umgebungsdatei war ein Umweg und ein
# zusätzlicher Fehlerfall ("Datei fehlt, keine Meldung, keine Ursache").
# =============================================================================

# Bewusst KEIN `set -e`. Ein Hook, der scheitert, soll still scheitern: die
# globale notify.sh des Hosts lief mit `set -e` und beendete deshalb JEDE
# Antwort mit einem Fehler, sobald `osascript` fehlte. Genau das nicht.
set -u

ART="${1:-}"
EVENTS="${2:-}"
SANDBOX="${3:-}"
SCHWELLE="${4:-60}"

# --- Selbstschutz: ohne brauchbare Angaben tun wir gar nichts ----------------
# Ein fehlender Rückkanal ist ein Komfortproblem, kein Grund, die Sitzung zu
# stören. Deshalb überall stilles `exit 0` und nie eine Fehlermeldung.
[ -n "$ART" ]     || exit 0
[ -n "$EVENTS" ]  || exit 0
[ -n "$SANDBOX" ] || exit 0
[ -d "$EVENTS" ]  || exit 0
[ -w "$EVENTS" ]  || exit 0

case "$SCHWELLE" in
  ''|*[!0-9]*) SCHWELLE=60 ;;
esac

# Der Dateiname trägt den Sandbox-Namen. Der Wächter nimmt ihn von dort und
# prüft ihn gegen ein Muster — deshalb darf hier nichts Wildes hinein.
case "$SANDBOX" in
  *[!A-Za-z0-9.+-]*) exit 0 ;;
esac
ZIEL="$EVENTS/$SANDBOX.ereignisse"

# Die Hook-Eingabe von stdin. Wir brauchen daraus nur die Sitzungskennung — aber
# gelesen werden muss stdin ohnehin, sonst kann der schreibende Prozess
# blockieren.
EINGABE="$(cat 2>/dev/null)" || EINGABE=""

# Startmarke PRO SITZUNG, in /tmp der Sandbox. Reine Innensache, hat auf dem
# Host nichts zu suchen.
#
# ⚠️  Die Sitzungskennung im Dateinamen ist nicht Zierrat. In einer Sandbox
#     können mehrere Claude-Sitzungen gleichzeitig laufen (ein zweites Terminal,
#     ein `sbx-claude shell` daneben). Mit einer festen Marke überschriebe die
#     eine Sitzung die Startzeit der anderen, und die gemeldeten Dauern wären
#     Zufallszahlen. Der Wert wird auf Namenszeichen beschränkt, weil er in
#     einen Dateinamen wandert.
SITZUNG=""
if command -v jq >/dev/null 2>&1 && [ -n "$EINGABE" ]; then
  SITZUNG="$(printf '%s' "$EINGABE" | jq -r '.session_id // empty' 2>/dev/null)" || SITZUNG=""
fi
case "$SITZUNG" in
  ''|*[!A-Za-z0-9._-]*) SITZUNG="ohne-kennung" ;;
esac
MARKE="${TMPDIR:-/tmp}/sbx-claude-start-$SITZUNG"

glocke() {
  # Markiert den Terminal-Tab sofort, noch bevor der Wächter reagiert. Der
  # Umweg über /dev/tty ist nötig, weil stdout eines Hooks nicht am Terminal
  # hängt.
  #
  # ⚠️  Die Klammern sind nötig. Bei `printf … > /dev/tty 2>/dev/null` meldet die
  #     SHELL den Öffnungsfehler, nicht printf — und die Umleitung gilt nur für
  #     printf. Ohne Terminal stand deshalb
  #       notify.sh: line 74: /dev/tty: Device not configured
  #     in der Ausgabe. Gemessen, nicht vermutet.
  { printf '\a' > /dev/tty; } 2>/dev/null || true
  return 0
}

melde() {
  # $1 = Ereigniswort aus fester Liste, $2 = Sekunden (nur Ziffern)
  printf '%s\t%s\n' "$1" "$2" >> "$ZIEL" 2>/dev/null
  glocke
}

case "$ART" in
  start)
    # UserPromptSubmit: nur die Uhr stellen, nichts melden.
    date +%s > "$MARKE" 2>/dev/null
    exit 0
    ;;

  stop)
    # Stop feuert nach JEDER Antwort. Ungefiltert wären das bei einem Dialog mit
    # dreißig Runden dreißig Meldungen — und dann schaltet man sie ab, womit die
    # zuverlässige Benachrichtigung nichts mehr wert ist. Deshalb die Schwelle:
    # gemeldet wird nur, was lange genug gedauert hat, dass man weggegangen ist.
    JETZT="$(date +%s 2>/dev/null)" || exit 0
    if [ -r "$MARKE" ]; then
      BEGINN="$(cat "$MARKE" 2>/dev/null)"
    else
      BEGINN=""
    fi
    rm -f "$MARKE" 2>/dev/null

    case "$BEGINN" in
      ''|*[!0-9]*) exit 0 ;;   # keine brauchbare Marke -> nichts melden
    esac

    DAUER=$((JETZT - BEGINN))
    [ "$DAUER" -ge 0 ] || exit 0
    [ "$DAUER" -ge "$SCHWELLE" ] || exit 0

    melde fertig "$DAUER"
    ;;

  wartet)
    # Notification: hier wartet Claude wirklich auf einen Menschen — auch bei
    # jeder git-Rückfrage. Immer melden, ohne Schwelle.
    melde wartet 0
    ;;

  *)
    exit 0
    ;;
esac

exit 0
