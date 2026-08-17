#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# sbx-claude — der Wächter. Läuft auf dem HOST, nicht in der Sandbox.
#
# Er ist das Gegenstück zu /usr/local/bin/sbx-claude-notify im Container. Die
# Kette lautet:
#
#   1. Claude läuft in einem Linux-Container und kann keine macOS-Meldung
#      erzeugen — `osascript` und `terminal-notifier` gibt es dort nicht.
#   2. Der Container kann den Mac auch nicht anrufen: keine Route, und die
#      Netz-Policy ist Deny-by-default.
#   3. Was es gibt, ist ein gemeinsamer Ordner. sbx hängt Host-Verzeichnisse
#      unter demselben absoluten Pfad ein, also ist eine Zeile, die der Hook
#      schreibt, im selben Moment eine echte Datei auf dem Mac.
#   4. Dieses Skript liest sie und macht die Meldung daraus.
#
# ⚠️  DIE WICHTIGSTE ZEILE DIESES SKRIPTS IST EINE PRÜFUNG.
#
#     Der Ereignisordner ist ein Kanal AUS der Sandbox auf den Host. Alles darin
#     ist vom Agenten beeinflussbar: Dateinamen wie Inhalte. Würden wir Text
#     daraus an `osascript` weitergeben, wäre das AppleScript-Injection — also
#     Codeausführung auf dem Mac, vorbei an der ganzen Sandbox. Ein bösartiger
#     Dateiname genügte.
#
#     Deshalb gilt hier ohne Ausnahme: Es wird NICHTS aus dem Container
#     übernommen, was nicht vorher gegen ein Muster geprüft wurde. Erlaubt sind
#     genau zwei Dinge — ein Wort aus einer festen Liste und eine Zahl. Den Text
#     der Meldung formuliert dieses Skript selbst. `terminal-notifier` bekommt
#     Argumente, nie eine Shell-Zeile.
#
# Aufruf: watch.sh <ereignisordner>
# =============================================================================

EVENTS_DIR="${1:-}"
[ -n "$EVENTS_DIR" ] || { echo "Aufruf: watch.sh <ereignisordner>" >&2; exit 1; }
[ -d "$EVENTS_DIR" ] || { echo "Ereignisordner fehlt: $EVENTS_DIR" >&2; exit 1; }

# Die Merkdatei für die Leseposition liegt BEWUSST nicht im Ereignisordner: dort
# darf der Container schreiben, hier nicht. Sonst könnte er unsere Position
# verstellen.
STATE_DIR="$(dirname "$EVENTS_DIR")"
OFFSET_DIR="$STATE_DIR/watch-offsets"
mkdir -p "$OFFSET_DIR"

meldung_zeigen() {
  # $1 = Titel, $2 = Untertitel, $3 = Text. Alle drei sind hier bereits
  # geprüfte oder selbst formulierte Werte.
  local titel="$1" unter="$2" text="$3"

  if command -v terminal-notifier >/dev/null 2>&1; then
    # Argumente, keine Shell-Zeile: terminal-notifier bekommt die Werte als
    # eigene argv-Einträge, es gibt also nichts zu maskieren.
    terminal-notifier -title "$titel" -subtitle "$unter" -message "$text" \
      -sound Glass >/dev/null 2>&1 || true
    return 0
  fi

  if command -v osascript >/dev/null 2>&1; then
    # osascript baut eine Zeichenkette und ist damit der gefährliche Weg. Er ist
    # nur deshalb vertretbar, weil alle drei Werte aus geprüften Bausteinen
    # bestehen: Anführungszeichen und Backslashes können darin nicht vorkommen.
    osascript -e "display notification \"$text\" with title \"$titel\" subtitle \"$unter\"" \
      >/dev/null 2>&1 || true
    return 0
  fi

  # Weder das eine noch das andere: dann eben auf das Terminal.
  printf '[sbx-claude] %s — %s: %s\n' "$titel" "$unter" "$text"
}

verarbeite_zeile() {
  local sandbox="$1" wort="$2" zahl="$3"

  # Prüfung 1: das Ereigniswort muss aus der festen Liste kommen.
  case "$wort" in
    fertig|wartet) ;;
    *) return 0 ;;
  esac

  # Prüfung 2: die Zahl muss eine Zahl sein. Nichts anderes.
  case "$zahl" in
    ''|*[!0-9]*) zahl=0 ;;
  esac

  # Der Projektname kommt aus dem Sandbox-Namen, und der ist schon geprüft.
  local projekt="${sandbox#sbx-claude-}"

  case "$wort" in
    fertig)
      meldung_zeigen "Claude — fertig" "$projekt" "Antwort nach ${zahl} Sekunden abgeschlossen."
      ;;
    wartet)
      meldung_zeigen "Claude wartet" "$projekt" "Es liegt eine Rueckfrage an, etwa zu git."
      ;;
  esac
}

durchgang() {
  local datei name offset_datei offset zeilen neu wort zahl

  for datei in "$EVENTS_DIR"/*.ereignisse; do
    [ -f "$datei" ] || continue
    name="$(basename "$datei" .ereignisse)"

    # ⚠️  Die Prüfung, um die es geht. Ein Dateiname darf nur aus dem Präfix und
    #     den von sbx erlaubten Namenszeichen bestehen. Alles andere ignorieren
    #     wir stillschweigend — ein Name wie '; rm -rf ~' kommt hier nicht
    #     weiter.
    case "$name" in
      sbx-claude-*) ;;
      *) continue ;;
    esac
    case "$name" in
      *[!A-Za-z0-9.+-]*) continue ;;
    esac

    offset_datei="$OFFSET_DIR/$name"
    offset="$(cat "$offset_datei" 2>/dev/null || echo 0)"
    case "$offset" in
      ''|*[!0-9]*) offset=0 ;;
    esac

    zeilen="$(wc -l < "$datei" 2>/dev/null | tr -d ' ')"
    case "$zeilen" in
      ''|*[!0-9]*) continue ;;
    esac

    # Die Datei ist kürzer als beim letzten Mal — sie wurde gekürzt oder neu
    # angelegt. Dann von vorn lesen statt Zeilen zu verpassen.
    [ "$zeilen" -lt "$offset" ] && offset=0

    if [ "$zeilen" -gt "$offset" ]; then
      neu="$(tail -n "+$((offset + 1))" "$datei" 2>/dev/null || true)"
      # ⚠️  Prozess-Substitution und KEIN Here-String (`<<< "$neu"`). Ein
      #     Here-String legt eine temporäre Datei an, und die ist nicht überall
      #     schreibbar — gemessen: in einer Sandbox mit eingeschränktem /tmp
      #     bricht er mit "cannot create temp file for here document" ab. Eine
      #     Pipe wäre auch falsch: sie steckte die Schleife in eine Subshell.
      while IFS="$(printf '\t')" read -r wort zahl; do
        [ -n "${wort:-}" ] || continue
        verarbeite_zeile "$name" "$wort" "${zahl:-0}"
      done < <(printf '%s\n' "$neu")
      printf '%s\n' "$zeilen" > "$offset_datei"
    fi
  done
}

printf 'sbx-claude: Waechter beobachtet %s\n' "$EVENTS_DIR"

# Beim Start nicht die ganze Historie nachmelden: einmal die aktuellen Längen
# notieren, dann erst horchen.
durchgang >/dev/null 2>&1 || true

if command -v fswatch >/dev/null 2>&1; then
  # fswatch ist genauer und sparsamer als Pollen, aber optional — es ist nicht
  # auf jedem Mac installiert.
  fswatch -o "$EVENTS_DIR" | while read -r _; do
    durchgang
  done
else
  # Zwei Sekunden auf ein paar kleine Dateien kostet nichts und ist gut genug
  # für eine Benachrichtigung.
  while :; do
    sleep 2
    durchgang
  done
fi
