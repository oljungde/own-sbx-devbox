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
    shared_mounts+=("$HOME/.claude/$d:ro")
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
link_shared_config() {
  info "verlinke globale Agents/Skills/Commands ..."
  local dirs="${CLAUDE_SHARED[*]}"
  sbx exec -d "$SANDBOX" bash -c "
    set -u
    mkdir -p \"\$HOME/.claude\"
    for d in $dirs; do
      if [ -d '$HOME/.claude/'\$d ]; then
        ln -sfn '$HOME/.claude/'\$d \"\$HOME/.claude/\$d\"
      fi
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
    [jJyY]) sbx rm --force "$SANDBOX"; info "entfernt." ;;
    *)      info "abgebrochen." ;;
  esac
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

usage() {
  cat <<'EOF'
devbox — eine Claude-Sandbox für mehrere Projekte

Aufruf: ./devbox.sh <kommando> [profil]

  build [--force]   Image bauen und als sbx-Template registrieren.
                    Übersprungen, solange sich das Dockerfile nicht geändert hat.

  up [profil]       Sandbox anlegen (beim ersten Mal) und Claude darin starten.
                    Ohne Angabe wird das Profil "privat" verwendet.

  shell [profil]    Eine bash-Shell in der laufenden Sandbox öffnen.

  allow <host> [profil]
                    Einen Host für diese Sandbox freigeben.

  doctor            Prüfen, ob alles bereitsteht.

  rm [profil]       Die Sandbox entfernen (fragt vorher nach).

Profile werden in ~/.config/devbox/devbox.conf definiert.
Vorlage: devbox.conf.example
EOF
}

# --- Einstiegspunkt ----------------------------------------------------------

case "${1:-}" in
  build)  shift; require_tools; cmd_build  "$@" ;;
  up)     shift; require_tools; cmd_up     "$@" ;;
  shell)  shift; require_tools; cmd_shell  "$@" ;;
  allow)  shift; require_tools; cmd_allow  "$@" ;;
  rm)     shift; require_tools; cmd_rm     "$@" ;;
  doctor) shift;                cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unbekanntes Kommando '$1'. './devbox.sh help' zeigt die Übersicht." ;;
esac
