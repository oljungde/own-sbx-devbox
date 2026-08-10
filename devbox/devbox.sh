#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# devbox.sh — Komfort-Wrapper um Docker Sandboxes (sbx)
#
# Dieses Skript erfindet nichts Neues. Es ruft nur `sbx`-Kommandos in der
# richtigen Reihenfolge auf und merkt sich, was sich seit dem letzten Mal
# geändert hat. Alles, was es tut, kannst du auch von Hand tippen — im Tutorial
# machen wir in Kapitel 1 bis 6 genau das, und erst in Kapitel 7 packen wir es
# hier hinein.
#
# Bewusst NUR stabile sbx-Flags. `sbx kit` und `sbx skills` sind in v0.38 als
# EXPERIMENTAL markiert ("may change or be removed in future releases") und
# haben deshalb hier nichts zu suchen — die Kit-Variante liegt als Kür in
# devbox/kit/kit.yaml.
#
# Aufruf:  ./devbox.sh <kommando> [profil]
# =============================================================================

# --- Konfiguration -----------------------------------------------------------

# Name des Templates (das "Muster-Zimmer") und Ablage für unseren Merkzettel.
# Beide Namen sind bewusst so gewählt, dass sie sich mit keinem anderen
# sbx-Setup auf dieser Maschine überschneiden.
IMAGE="devbox/base:latest"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/devbox"

# Wo dieses Skript und das Dockerfile liegen — unabhängig davon, aus welchem
# Verzeichnis heraus du das Skript aufrufst.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

# Profile beschreiben, welche Ordner eine Sandbox sieht. Beispieldatei:
# devbox.conf.example. Die eigene Kopie liegt bewusst außerhalb des Repos,
# damit persönliche Pfade nicht versehentlich committet werden.
CONFIG_FILE="${DEVBOX_CONFIG:-$HOME/.config/devbox/devbox.conf}"

# Diese Unterordner von ~/.claude werden read-only in die Sandbox gehängt.
# Absicht dahinter: Skills und Agents, die du in ALLEN Projekten brauchst,
# sollen an EINER Stelle liegen — nicht in jedem Projekt als Kopie.
#
# Bewusst NICHT dabei:
#   settings.json    — enthält Berechtigungen für deinen Host, nicht für einen Container
#   .credentials.json— dein Zugangstoken hat in der Sandbox nichts verloren
#   projects/, todos/— reiner Host-Zustand
CLAUDE_SHARED=(agents skills commands rules plugins)

# Und diese davon werden zusätzlich nach /home/agent/.claude/<name> verlinkt,
# damit Claude sie dort findet.
#
# ⚠️  `skills` fehlt hier ABSICHTLICH. sbx hängt an /home/agent/.claude/skills
#     seinen EIGENEN Skill-Store ein — und zwar denselben für alle Sandboxes
#     auf dieser Maschine. Ein `ln -sfn` dorthin scheitert nicht etwa, sondern
#     legt den Link STILL IN diesen Store hinein. Damit läge unsere
#     Konfiguration plötzlich auch in jeder anderen Sandbox des Rechners.
#     Nachgemessen beim Bauen dieses Repos — siehe docs/architektur.md.
#     Der Ordner wird oben trotzdem gemountet, ist also unter seinem
#     Host-Pfad in der Sandbox lesbar.
CLAUDE_LINKED=(agents commands rules plugins)

# Netzwerk: bewusst kurz gehalten. Die Sandbox darf standardmäßig NUR das hier.
# Fehlt dir ein Host, ist das kein Fehler, sondern der Normalfall — füge ihn mit
# `./devbox.sh allow <host>` hinzu. Genau diese Übung steht in Kapitel 4.
BASE_HOSTS=(
  api.anthropic.com          # Claude selbst
  '*.claude.ai'              # Login und Connectors
  github.com                 # git clone / push
  '*.githubusercontent.com'  # Rohdateien von GitHub
  '*.npmjs.org'              # npm / pnpm
  pypi.org                   # pip / uv / poetry
  files.pythonhosted.org     # die eigentlichen Python-Pakete
  '*.astral.sh'              # uv-Updates und Python-Interpreter
  '*.aikido.dev'             # Safe-Chain-Prüfungen
)

# --- Kleine Helfer -----------------------------------------------------------

info() { printf '>> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

# Profil laden und daraus NAME, WORKSPACES und EXTRA_HOSTS setzen.
# Ein Profil ist einfach eine Bash-Datei, die diese drei Variablen definiert.
load_profile() {
  local profile="${1:-privat}"

  [ -f "$CONFIG_FILE" ] || die "Keine Konfiguration unter '$CONFIG_FILE'.
       Kopiere devbox.conf.example dorthin und passe die Pfade an."

  # Vor dem Laden zurücksetzen, damit ein unvollständiges Profil auffällt statt
  # heimlich Werte eines anderen zu erben.
  NAME=""; WORKSPACES=(); EXTRA_HOSTS=()
  # shellcheck disable=SC2034  # wird nicht hier, sondern in der Profildatei gelesen
  DEVBOX_PROFILE="$profile"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  [ -n "$NAME" ] || die "Profil '$profile' setzt kein NAME."
  [ "${#WORKSPACES[@]}" -gt 0 ] || die "Profil '$profile' setzt keine WORKSPACES."

  SANDBOX="devbox-$NAME"
}

require_tools() {
  for t in sbx docker; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' ist nicht installiert."
  done
}

sandbox_exists() { sbx ls -q 2>/dev/null | grep -qx "$SANDBOX"; }

hash_file()     { printf '%s\n' "$STATE_DIR/image.hash"; }
recorded_hash() { cat "$(hash_file)" 2>/dev/null || true; }
current_hash()  { shasum -a 256 "$DOCKERFILE" | cut -d' ' -f1; }

# Die ID des Templates, das derzeit im sbx-Store liegt — oder leer, wenn keins
# geladen ist. `sbx template load` stellt dem Namen "docker.io/" voran, aus
# "devbox/base:latest" wird dort also "docker.io/devbox/base" + Tag "latest".
#
# Warum die Tabelle parsen und nicht `--json`? Weil `jq` auf dem Host nicht
# vorausgesetzt werden soll. awk ist überall da.
#
# Das `|| true` am Ende ist nicht Bequemlichkeit, sondern Notwendigkeit:
# `sbx template ls` endet mit Exitcode 1, solange man nicht bei Docker
# angemeldet ist ("ERROR: Not authenticated to Docker"). Wegen `pipefail` würde
# dieser Status in die Zuweisung wandern und wegen `set -e` das ganze Skript
# beenden — und zwar stumm. Eine leere Antwort ist hier die richtige Antwort;
# die Aufrufer behandeln sie.
template_id() {
  local repo="docker.io/${IMAGE%:*}" tag="${IMAGE##*:}"
  sbx template ls 2>/dev/null \
    | awk -v r="$repo" -v t="$tag" '$1==r && $2==t { print $3; exit }' || true
}

# Merkzettel: mit WELCHER Template-ID wurde eine Sandbox angelegt?
#
# Das muss der Wrapper selbst mitschreiben — `sbx ls` verrät es nicht. Und
# wissen müssen wir es, weil ein neu gebautes Template eine BESTEHENDE Sandbox
# nicht erreicht: Container werden beim Anlegen aus dem Template kopiert, nicht
# laufend daran angeglichen. Ohne diesen Zettel wäre `update` blind.
sandbox_image_file() { printf '%s\n' "$STATE_DIR/sandbox-$1.image"; }
recorded_sandbox_image() { cat "$(sandbox_image_file "$1")" 2>/dev/null || true; }

# Die Namen UNSERER Sandboxes, eine pro Zeile. Das Präfix ist die Grenze: alles
# ohne "devbox-" gehört einem anderen Setup auf dieser Maschine und wird von
# diesem Skript nie angefasst.
# `|| true` aus demselben Grund wie bei template_id.
devbox_sandboxes() { sbx ls -q 2>/dev/null | grep '^devbox-' || true; }

# --- build: Image bauen und als sbx-Template registrieren --------------------
#
# Warum der Umweg über eine tar-Datei? Der Docker-Daemon, den sbx benutzt, ist
# NICHT derselbe wie dein lokaler. Er sieht deine lokal gebauten Images nicht.
# `docker save` + `sbx template load` schiebt das Image von dem einen in den
# anderen. (Das ist auch der Grund, warum dieser Schritt ein paar Gigabyte
# bewegt und entsprechend dauert.)
cmd_build() {
  local now recorded
  now="$(current_hash)"
  recorded="$(recorded_hash)"

  if [ "$now" = "$recorded" ] && [ "${1:-}" != "--force" ]; then
    info "Dockerfile unverändert — Bau übersprungen. (Erzwingen: build --force)"
    return 0
  fi

  info "baue Image '$IMAGE' ..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$SCRIPT_DIR"

  local tarball
  tarball="$(mktemp -t devbox-image.XXXXXX.tar)"
  info "exportiere das Image (dauert bei mehreren GB einen Moment) ..."
  docker save "$IMAGE" -o "$tarball"
  info "Größe: $(du -h "$tarball" | cut -f1)"

  info "lade das Image in den sbx-Template-Store ..."
  sbx template load "$tarball"
  rm -f "$tarball"

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$now" > "$(hash_file)"
  info "fertig. Template '$IMAGE' steht bereit."
}

# --- up: Sandbox anlegen (falls nötig) und Claude starten --------------------
cmd_up() {
  load_profile "${1:-privat}"

  # sbx bricht ab, wenn ein zu mountender Ordner nicht existiert. Gerade bei
  # frisch eingerichteten Rechnern fehlt z.B. ~/.claude/rules noch — also legen
  # wir die fehlenden Ordner still an, statt den Start scheitern zu lassen.
  local shared_mounts=()
  for d in "${CLAUDE_SHARED[@]}"; do
    mkdir -p "$HOME/.claude/$d"
    # Klammern um $d sind hier kein Zierrat: in zsh würde "$HOME/.claude/$d:ro"
    # als History-Modifier ":r" gelesen und ergäbe "…/agentso" statt
    # "…/agents:ro". Mit ${d} ist es in jeder Shell eindeutig.
    shared_mounts+=("$HOME/.claude/${d}:ro")
  done

  if ! sandbox_exists; then
    info "lege Sandbox '$SANDBOX' aus Template '$IMAGE' an ..."
    # WICHTIG: Workspaces können NUR beim Anlegen gesetzt werden. sbx lehnt sie
    # an einer bestehenden Sandbox ab. Deshalb mounten wir in WORKSPACES einen
    # DACH-Ordner (z.B. ~/dev/own) und nicht einzelne Projekte — sonst kostet
    # jedes neue Projekt einen kompletten Neuaufbau.
    #
    # Der erste Pfad ist der Primary Workspace, dort startet der Agent. Alle
    # weiteren werden unter ihrem absoluten Host-Pfad eingehängt.
    sbx create -t "$IMAGE" --name "$SANDBOX" claude \
      "${WORKSPACES[@]}" \
      "${shared_mounts[@]}"

    # Festhalten, aus welchem Template diese Sandbox entstanden ist. Genau
    # daran erkennt `status` und `update` später, ob sie veraltet ist.
    mkdir -p "$STATE_DIR"
    template_id > "$(sandbox_image_file "$SANDBOX")"
  else
    info "Sandbox '$SANDBOX' existiert bereits — hänge mich dran."
  fi

  apply_network
  link_shared_config

  info "starte Claude in '$SANDBOX' ..."
  sbx run --name "$SANDBOX" claude
}

# --- Netzwerkregeln setzen ---------------------------------------------------
#
# Ausschließlich --sandbox-scoped. Das ist wichtig, falls auf diesem Rechner
# noch ein anderes sbx-Setup läuft: eine globale Regel würde dessen Policy
# mitverändern, eine sandbox-scoped Regel gilt nur für uns.
apply_network() {
  info "setze Netzwerkregeln für '$SANDBOX' ..."
  local host
  for host in "${BASE_HOSTS[@]}" ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do
    # "Already covered in policy" ist der Normalfall ab dem zweiten Start und
    # kein Fehler — deshalb filtern wir es aus der Ausgabe heraus.
    sbx policy allow network --sandbox "$SANDBOX" "$host" 2>&1 \
      | grep -vF 'Already covered in policy' || true
  done
}

# --- Globale Claude-Konfiguration verlinken ----------------------------------
#
# Warum überhaupt Symlinks? Extra-Workspaces landen in der Sandbox unter ihrem
# absoluten HOST-Pfad — also z.B. /Users/du/.claude/skills. Claude sucht seine
# Skills aber in /home/agent/.claude/skills. Der Symlink verbindet beides.
#
# Die Prüfung auf "ist das Ziel schon ein echtes Verzeichnis?" ist die
# Sicherung gegen den oben beschriebenen Fall: Zeigt der Zielpfad auf ein
# eingehängtes Verzeichnis, würde `ln -sfn` den Link hineinlegen statt es zu
# ersetzen — und zwar ohne Fehlermeldung. Dann lieber gar nichts tun und es
# sagen.
link_shared_config() {
  info "verlinke globale Agents/Commands/Rules/Plugins ..."
  local dirs="${CLAUDE_LINKED[*]}"
  sbx exec -d "$SANDBOX" bash -c "
    set -u
    mkdir -p \"\$HOME/.claude\"
    for d in $dirs; do
      quelle='$HOME/.claude/'\$d
      ziel=\"\$HOME/.claude/\$d\"
      [ -d \"\$quelle\" ] || continue
      if [ -d \"\$ziel\" ] && [ ! -L \"\$ziel\" ]; then
        echo \"Hinweis: \$ziel ist ein echtes Verzeichnis (vermutlich von sbx eingehaengt) — uebersprungen.\" >&2
        continue
      fi
      ln -sfn \"\$quelle\" \"\$ziel\"
    done
  "
}

# --- Weitere Kommandos -------------------------------------------------------

cmd_shell() {
  load_profile "${1:-privat}"
  sandbox_exists || die "Sandbox '$SANDBOX' existiert nicht. Erst './devbox.sh up' laufen lassen."
  sbx exec -it "$SANDBOX" bash
}

cmd_allow() {
  local host="${1:-}"; shift || true
  [ -n "$host" ] || die "Aufruf: ./devbox.sh allow <host> [profil]"
  load_profile "${1:-privat}"
  sbx policy allow network --sandbox "$SANDBOX" "$host"
  info "'$host' für '$SANDBOX' freigegeben."
  info "Damit es dauerhaft gilt, trage den Host als EXTRA_HOSTS in $CONFIG_FILE ein."
}

cmd_rm() {
  load_profile "${1:-privat}"
  warn "Das Entfernen von '$SANDBOX' löscht den Zustand IN der Sandbox:"
  warn "  - zur Laufzeit installierte Pakete"
  warn "  - der Claude-Login (du musst dich neu anmelden)"
  warn "  - Änderungen an /etc/sandbox-persistent.sh"
  warn "Deine Projektdateien liegen auf dem Host und sind NICHT betroffen."
  read -r -p "Sandbox '$SANDBOX' wirklich entfernen? [j/N] " answer
  case "$answer" in
    [jJyY])
      sbx rm --force "$SANDBOX"
      # Den Merkzettel mitnehmen — sonst behauptet `status` später, eine längst
      # entfernte Sandbox sitze auf einem veralteten Template.
      rm -f "$(sandbox_image_file "$SANDBOX")"
      info "entfernt."
      ;;
    *) info "abgebrochen." ;;
  esac
}

# --- status: Wer läuft, auf welchem Template, mit welchen Regeln? ------------
#
# Abgrenzung zu `doctor`: doctor fragt "ist mein HOST richtig eingerichtet?",
# status fragt "was läuft gerade?". Deshalb braucht status auch `sbx`, doctor
# nicht.
cmd_status() {
  local id
  id="$(template_id)"

  echo "--- Template ---"
  if [ -n "$id" ]; then
    printf '  ✓ %s  (ID %s)\n' "$IMAGE" "$id"
    if [ "$(current_hash)" = "$(recorded_hash)" ]; then
      echo "    Dockerfile unverändert seit dem letzten Bau"
    else
      echo "    ! Dockerfile hat sich geändert — './devbox.sh update'"
    fi
  else
    echo "  ✗ kein Template '$IMAGE' im sbx-Store"
    echo "    Entweder noch nicht gebaut ('./devbox.sh build') — oder du bist"
    echo "    nicht angemeldet ('sbx login'). Beides sieht von hier gleich aus."
  fi

  echo "--- Unsere Sandboxes (Präfix 'devbox-') ---"
  local eigene=0 fremde=0 name zustand vermerk
  # Warum die Ausgabe von `sbx ls` und nicht `sbx ls -q`? Weil wir den Zustand
  # (running/stopped) mitlesen wollen. Spalten: NAME AGENT STATUS [PORTS] ...
  # PORTS ist meist leer, deshalb greifen wir nur auf $1 und $3 zu.
  while read -r name zustand; do
    [ -n "$name" ] || continue
    eigene=$((eigene + 1))

    vermerk="$(recorded_sandbox_image "$name")"
    if [ -z "$vermerk" ]; then
      vermerk="Template unbekannt (vor dieser devbox-Version angelegt?)"
    elif [ "$vermerk" = "$id" ]; then
      vermerk="Template aktuell"
    else
      vermerk="Template VERALTET ($vermerk) — 'update' erklärt, was zu tun ist"
    fi

    printf '  %-22s %-9s %s\n' "$name" "$zustand" "$vermerk"
    # Prozess-Substitution, KEINE Pipe. Eine Pipe würde die Schleife in eine
    # Subshell stecken, und $eigene wäre danach wieder 0. Ein Here-Doc ginge
    # auch, braucht aber eine Temp-Datei — und die ist in einer Sandbox nicht
    # überall schreibbar.
  done < <(sbx ls 2>/dev/null | awk 'NR > 1 && $1 ~ /^devbox-/ { print $1, $3 }' || true)
  [ "$eigene" -gt 0 ] || echo "  (keine — './devbox.sh up <profil>')"

  # Der Blick auf die Nachbarn ist kein Selbstzweck: Er macht sichtbar, warum
  # jede Netzregel in diesem Skript --sandbox-scoped ist. Diese Sandboxes
  # gehören jemand anderem, und eine globale Regel würde sie mitverändern.
  fremde="$(sbx ls 2>/dev/null | awk 'NR > 1 && $1 !~ /^devbox-/' | wc -l | tr -d ' ' || true)"
  echo "--- Andere Sandboxes auf dieser Maschine ---"
  if [ "$fremde" -gt 0 ]; then
    printf '  %s — von unseren Regeln unberührt (alle sind --sandbox-scoped)\n' "$fremde"
  else
    echo "  keine"
  fi

  echo
  echo "Netzregeln einer Sandbox ansehen: sbx policy ls devbox-<name>"
}

# --- update: neues Template bauen und sagen, wen es noch nicht erreicht ------
#
# Der Fallstrick, den dieses Kommando sichtbar macht: `build` erzeugt ein neues
# Template, aber eine bereits bestehende Sandbox merkt davon NICHTS. Sie wurde
# beim Anlegen aus dem alten Template kopiert und bleibt darauf. Wer das nicht
# weiß, ändert das Dockerfile, baut neu — und sucht anschließend lange, warum
# das neue Werkzeug in der Sandbox fehlt.
cmd_update() {
  cmd_build --force

  local aktuell veraltet=0 gesamt=0 name vermerk
  aktuell="$(template_id)"

  echo
  # Ohne bekannte Ziel-ID wäre jeder Vergleich unten geraten — dann lieber
  # nichts behaupten.
  if [ -z "$aktuell" ]; then
    warn "Template-ID nicht lesbar — überspringe den Abgleich."
    warn "Prüfe 'sbx login' und danach './devbox.sh status'."
    return 0
  fi

  info "prüfe, welche Sandboxes noch auf einem älteren Template sitzen ..."
  while read -r name; do
    [ -n "$name" ] || continue
    gesamt=$((gesamt + 1))
    vermerk="$(recorded_sandbox_image "$name")"
    if [ -z "$vermerk" ]; then
      warn "  $name — unbekannt, aus welchem Template angelegt"
      veraltet=$((veraltet + 1))
    elif [ "$vermerk" != "$aktuell" ]; then
      warn "  $name — noch auf $vermerk (neu ist $aktuell)"
      veraltet=$((veraltet + 1))
    else
      info "  $name — aktuell"
    fi
  done < <(devbox_sandboxes)

  if [ "$gesamt" -eq 0 ]; then
    info "Keine Sandbox vorhanden — das neue Template wird beim nächsten"
    info "'./devbox.sh up <profil>' verwendet."
  elif [ "$veraltet" -gt 0 ]; then
    echo
    warn "Ein neues Template erreicht eine bestehende Sandbox NICHT. Damit sie es"
    warn "bekommt, muss sie einmal neu angelegt werden:"
    warn ""
    warn "    ./devbox.sh rm <profil> && ./devbox.sh up <profil>"
    warn ""
    warn "Das kostet den Claude-Login und zur Laufzeit installierte Pakete."
    warn "Deine Projektdateien liegen auf dem Host und bleiben unberührt."
  else
    info "Alle unsere Sandboxes sind auf dem neuen Template."
  fi
}

cmd_doctor() {
  local ok=0
  echo "--- Werkzeuge auf dem Host ---"
  for t in sbx docker git gh; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '  ✓ %-6s %s\n' "$t" "$(command -v "$t")"
    else
      printf '  ✗ %-6s fehlt\n' "$t"; ok=1
    fi
  done

  echo "--- Template ---"
  if [ "$(current_hash)" = "$(recorded_hash)" ]; then
    echo "  ✓ Template ist auf dem Stand des Dockerfiles"
  else
    echo "  ! Dockerfile hat sich geändert — './devbox.sh build' ausführen"
  fi

  echo "--- Konfiguration ---"
  if [ -f "$CONFIG_FILE" ]; then
    echo "  ✓ $CONFIG_FILE"
  else
    echo "  ✗ $CONFIG_FILE fehlt (aus devbox.conf.example kopieren)"; ok=1
  fi

  echo "--- Geteilte Claude-Ordner ---"
  for d in "${CLAUDE_SHARED[@]}"; do
    if [ -d "$HOME/.claude/$d" ]; then
      printf '  ✓ ~/.claude/%-9s (%s Einträge)\n' "$d" "$(find "$HOME/.claude/$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    else
      printf '  · ~/.claude/%-9s fehlt — wird beim nächsten "up" angelegt\n' "$d"
    fi
  done

  return "$ok"
}

# Bewusst `printf` statt `cat <<EOF`: Ein Here-Doc legt die Zeilen erst in eine
# temporäre Datei. In einer eingeschränkten Umgebung — etwa wenn du devbox von
# INNERHALB einer Sandbox aufrufst — ist das Temp-Verzeichnis nicht schreibbar,
# und dann scheitert schon die Hilfe. printf braucht keine Datei.
usage() {
  printf '%s\n' \
    'devbox — eine Claude-Sandbox für mehrere Projekte' \
    '' \
    'Aufruf: ./devbox.sh <kommando> [profil]' \
    '' \
    '  build [--force]   Image bauen und als sbx-Template registrieren.' \
    '                    Übersprungen, solange sich das Dockerfile nicht geändert hat.' \
    '' \
    '  up [profil]       Sandbox anlegen (beim ersten Mal) und Claude darin starten.' \
    '                    Ohne Angabe wird das Profil "privat" verwendet.' \
    '' \
    '  shell [profil]    Eine bash-Shell in der laufenden Sandbox öffnen.' \
    '' \
    '  allow <host> [profil]' \
    '                    Einen Host für diese Sandbox freigeben.' \
    '' \
    '  status            Zeigen, was läuft: Template, unsere Sandboxes, deren Stand.' \
    '' \
    '  update            Template neu bauen und sagen, welche Sandboxes es noch' \
    '                    nicht erreicht hat.' \
    '' \
    '  doctor            Prüfen, ob der Host alles bereithält.' \
    '' \
    '  rm [profil]       Die Sandbox entfernen (fragt vorher nach).' \
    '' \
    'Profile werden in ~/.config/devbox/devbox.conf definiert.' \
    'Vorlage: devbox.conf.example'
}

# --- Einstiegspunkt ----------------------------------------------------------

case "${1:-}" in
  build)  shift; require_tools; cmd_build  "$@" ;;
  up)     shift; require_tools; cmd_up     "$@" ;;
  shell)  shift; require_tools; cmd_shell  "$@" ;;
  allow)  shift; require_tools; cmd_allow  "$@" ;;
  status) shift; require_tools; cmd_status "$@" ;;
  update) shift; require_tools; cmd_update "$@" ;;
  rm)     shift; require_tools; cmd_rm     "$@" ;;
  doctor) shift;                cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unbekanntes Kommando '$1'. './devbox.sh help' zeigt die Übersicht." ;;
esac
