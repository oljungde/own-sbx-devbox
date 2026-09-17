#!/usr/bin/env bash

# ⚠️  Läuft dieses Skript wirklich unter bash? `sh solobox.sh` ignoriert die
#     Shebang-Zeile oben, und /bin/sh ist auf macOS eine Bash 3.2 im
#     POSIX-Modus. Die kennt keine Prozess-Substitution und bricht mitten im
#     Skript ab — mit einer Meldung, die nach einem Tippfehler in einer Zeile
#     weit hinten aussieht statt nach einem falschen Startbefehl:
#
#       solobox.sh: line 488: syntax error near unexpected token `<'
#
#     Zwei Fälle sind zu unterscheiden, und der zweite ist der gemeine:
#       1. eine andere Shell (zsh, dash) -> BASH_VERSION ist leer
#       2. bash IM POSIX-MODUS, weil als `sh` aufgerufen -> BASH_VERSION ist
#          gesetzt! Erkennbar nur an `shopt -qo posix` (nachgemessen: unter
#          `sh` an, unter bash aus).
#
#     Statt zu meckern starten wir uns selbst unter bash neu — dann funktioniert
#     auch `sh solobox.sh`. Der Hinweis geht nach stderr, damit man es lernt.
#     Diese Prüfung steht ganz vorne und ist bewusst in POSIX-Syntax gehalten:
#     bash liest Skripte stückweise, sie greift also, bevor die erste
#     unverdauliche Zeile erreicht wird. `shopt` wird nur ausgewertet, wenn
#     BASH_VERSION gesetzt ist — in zsh gäbe es das Kommando nicht.
if [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; then
  if command -v bash >/dev/null 2>&1; then
    echo "Hinweis: solobox.sh braucht bash — ich starte mich neu." >&2
    echo "Hinweis: kürzer wäre './solobox.sh' oder 'bash solobox.sh'." >&2
    exec bash "$0" "$@"
  fi
  echo "FEHLER: solobox.sh braucht bash, und bash ist nicht installiert." >&2
  exit 1
fi

set -euo pipefail

# =============================================================================
# solobox.sh — EINE Sandbox für alles
#
# Der Unterschied zu devbox.sh in einem Satz: devbox fragt "welches Profil?",
# solobox fragt nichts. Es gibt genau eine Sandbox auf dieser Maschine, sie
# heißt "solobox", und sie sieht deine Projekte und deine globale
# Claude-Konfiguration.
#
# Gestartet wird IM PROJEKT: `solobox up` nimmt das aktuelle Verzeichnis und
# startet Claude genau dort. Das ist kein Komfort, sondern Notwendigkeit —
# Claude Code liest CLAUDE.md, .claude/ und .mcp.json eines Projekts beim START
# aus dem Arbeitsverzeichnis. Ein `cd` in der laufenden Sitzung holt das nicht
# nach.
#
# Wie devbox.sh benutzt auch dieses Skript bewusst nur stabile sbx-Flags. Die
# EINE Ausnahme ist `--no-share-skills` (siehe ISOLATE_SKILLS weiter unten) —
# sie ist ausdrücklich gekennzeichnet, standardmäßig aus, und das Skript
# überlebt es, wenn das Flag eines Tages verschwindet.
#
# Aufruf:  solobox <kommando> [argument]
# =============================================================================

# --- Feste Größen ------------------------------------------------------------

# Der Name ist Programm: eine Sandbox, ein Name, kein Profil-Parameter.
SANDBOX="solobox"
IMAGE="solobox/base:latest"

# Das Basis-Image aus der ersten Zeile des Dockerfiles. Steht hier nur, damit
# `check --base` fragen kann, ob es sich in der Registry bewegt hat. Ändert sich
# die FROM-Zeile, gehört diese hier mitgeändert.
BASE_IMAGE="docker/sandbox-templates:claude-code-docker"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/solobox"

# ⚠️  Symlinks auflösen, BEVOR aus dem Skriptpfad das Verzeichnis wird.
#     `solobox` wird über einen Symlink in ~/.local/bin aufgerufen (siehe
#     `install`). Ohne Auflösung zeigt ${BASH_SOURCE[0]} genau dorthin, und das
#     Skript sucht sein Dockerfile in ~/.local/bin:
#
#       shasum: /Users/du/.local/bin/Dockerfile: No such file or directory
#
#     Nachgemessen: Der Fehler blieb lange verborgen, weil der alte Ablauf
#     `current_hash` nur in einem Zweig aufrief. Seit `check` es immer tut,
#     schlägt er bei jedem Aufruf über den Symlink zu.
#
#     `readlink -f` gibt es auf macOS nicht verlässlich (BSD-readlink kennt das
#     Flag erst in neueren Versionen), deshalb die Schleife. Sie folgt auch einer
#     Kette von Symlinks und behandelt relative Ziele.
aufloesen() {
  local pfad="$1" ziel
  while [ -L "$pfad" ]; do
    ziel="$(readlink "$pfad")"
    case "$ziel" in
      /*) pfad="$ziel" ;;
      *)  pfad="$(dirname "$pfad")/$ziel" ;;
    esac
  done
  printf '%s\n' "$pfad"
}

SCRIPT_PATH="$(aufloesen "${BASH_SOURCE[0]}")"
SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$(basename "$SCRIPT_PATH")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

# Sofort prüfen statt später mit einer shasum-Fehlermeldung zu scheitern: Ohne
# das Dockerfile daneben kann dieses Skript nichts bauen und nichts vergleichen.
if [ ! -f "$DOCKERFILE" ]; then
  printf 'FEHLER: Dockerfile nicht gefunden: %s\n' "$DOCKERFILE" >&2
  printf 'FEHLER: solobox.sh erwartet es im selben Ordner. Wurde das Repo verschoben?\n' >&2
  printf 'FEHLER: Dann den Symlink neu setzen: <repo>/v2/solobox.sh install\n' >&2
  exit 1
fi

# Wohin `install` den Symlink legt. ~/.local/bin liegt auf den meisten Systemen
# schon auf dem PATH.
BIN_LINK="${SOLOBOX_BIN:-$HOME/.local/bin/solobox}"

# Die Konfiguration ist OPTIONAL. Ohne sie gelten die Standardwerte unten —
# `solobox up` funktioniert also unmittelbar nach dem Auschecken.
CONFIG_FILE="${SOLOBOX_CONFIG:-$HOME/.config/solobox/solobox.conf}"

# --- Standardwerte (von der Konfiguration überschreibbar) --------------------

# ⚠️  ROOTS ist die einzige Ein-Weg-Entscheidung in diesem Skript.
#     sbx nimmt Workspaces NUR beim Anlegen der Sandbox entgegen; an einer
#     bestehenden lehnt es sie ab. Was hier beim ersten `up` fehlt, lässt sich
#     später nur durch Entfernen und Neuanlegen nachrüsten — und das kostet den
#     Claude-Login und alles, was zur Laufzeit in der Sandbox installiert wurde.
#     Deshalb: DACH-Ordner eintragen, nicht einzelne Projekte.
#     Der ERSTE Eintrag ist der Primary Workspace. Ein ":ro" am Ende macht einen
#     Pfad schreibgeschützt.
#
# ⚠️  NUR VERZEICHNISSE. sbx lehnt eine einzelne Datei ab:
#       ERROR: workspace path exists but is not a directory: /Users/du/.gitconfig
#     Eine Datei wie ~/.gitconfig gehört deshalb nicht hierher — für die
#     Git-Identität sorgt apply_git_identity() weiter unten.
ROOTS=(
  "$HOME/dev"            # alle Projekte auf einmal — own und work liegen darunter
)

# Zusätzliche Hosts über die Grundliste hinaus.
EXTRA_HOSTS=()

# Namen von Servern, die auf dem Host mit `sbx mcp add` registriert wurden.
# Sie werden bei jedem `up` in die laufende Sandbox geladen. `sbx mcp ls` zeigt,
# was registriert ist.
MCP_SERVERS=()

# Hooks aus deiner globalen settings.json, die in der Sandbox NICHT gelten
# sollen. Voreingestellt sind die beiden Desktop-Benachrichtigungen: sie rufen
# `terminal-notifier` bzw. `osascript` auf — beides gibt es in einem
# Linux-Container nicht, und weil notify.sh mit `set -e` läuft, endet der Hook
# dann mit einem Fehler statt still zu bleiben. Kapitel 3 zeigt das einmal live.
HOOK_SKIP=(Notification Stop)

# Berechtigungsmodus IN der Sandbox. Erlaubt: acceptEdits, default, plan,
# bypassPermissions.
#
# Warum das überhaupt eine Variable ist: Das Basis-Image hinterlässt
# `bypassPermissions` in der settings.json. Für solobox stimmt diese Rechnung nur
# halb, denn `~/dev` ist ECHT eingehängt und beschreibbar. Voreinstellung ist
# deshalb `acceptEdits`.
#
# ⚠️  Erwarte davon aber KEINE Rückfrage bei jedem Bash-Aufruf. Nachgemessen:
#     Claude Code betreibt in der Sandbox seinen eigenen Bash-Sandkasten und
#     lässt Befehle, die darin laufen, ohne Rückfrage zu (autoAllowBashIfSandboxed).
#     Die eigentliche Grenze ist das ARBEITSVERZEICHNIS: ein Schreibversuch
#     darin gelingt, einer außerhalb wird hart geblockt ("Schreibzugriff
#     außerhalb des erlaubten Arbeitsverzeichnisses blockiert").
#     Genau deshalb startet cmd_up im Projekt und nicht in der Wurzel — das
#     begrenzt den Radius wirksamer als jede Einstellung hier.
#
# ⚠️  apply_settings entfernt dafür zwei Schlüssel, die das Image auf der
#     OBERSTEN Ebene der settings.json hinterlässt ("defaultMode" und
#     "bypassPermissionsModeAccepted"). Sie stehen neben dem dokumentierten
#     "permissions.defaultMode" und sagen etwas anderes. Welcher von beiden im
#     Zweifel gewinnt, ist nicht dokumentiert — und genau deshalb bleibt nur
#     einer stehen. Zwei widersprüchliche Angaben sind in jedem Fall die
#     schlechtere Lage.
PERMISSION_MODE="acceptEdits"

# ⚠️  ISOLATE_SKILLS=1 setzt beim Anlegen `--no-share-skills`.
#     Standard ist 0, und das aus zwei Gründen: das Flag ist in
#     `sbx create --help` nicht dokumentiert (es gehört zum als EXPERIMENTAL
#     markierten `sbx skills`), und dieses Repo hält sich sonst strikt an
#     stabile Flags.
#
#     Was der Schalter bewirkt: Ohne ihn ist /home/agent/.claude/skills der
#     Skill-Store von sbx — read-write und von ALLEN Sandboxes dieser Maschine
#     geteilt. Deine globalen Skills landen dort also auch in fremden
#     Sandboxes. Auf einem Rechner, auf dem nur deine eigenen Sandboxes laufen,
#     ist das die gewollte Bequemlichkeit. Auf einem geteilten Rechner ist es
#     ein Seitenkanal — dann gehört hier eine 1 hin.
#     `solobox status` zeigt jederzeit, wer sich den Store mit dir teilt.
ISOLATE_SKILLS=0

# --- Was aus ~/.claude in die Sandbox kommt ----------------------------------
#
# Diese Ordner werden read-only als zusätzliche Workspaces eingehängt. Genau
# das ist der Zweck dieser Variante: Skills, Agents, Commands und Regeln liegen
# EINMAL auf dem Host und gelten überall — du musst sie nicht in jedes Projekt
# kopieren.
#
# Bewusst NICHT dabei:
#   settings.json     — enthält Berechtigungen und Pfade DEINES Hosts. Was davon
#                       in der Sandbox gelten soll, wird abgeleitet statt
#                       gemountet (siehe apply_settings).
#   .credentials.json — dein Zugangstoken. Die Sandbox meldet sich selbst an.
#   .claude.json      — Sitzungszustand, vermischt mit MCP-Einträgen.
#   projects/ history.jsonl sessions/ file-history/ ide/ — reiner Host-Zustand.
CLAUDE_SHARED=(agents skills commands rules plugins hooks output-styles workflows)

# Und diese davon werden zusätzlich nach /home/agent/.claude/<name> verlinkt,
# damit Claude sie dort findet, wo es sie sucht.
#
# ⚠️  `skills` fehlt hier ABSICHTLICH — siehe ISOLATE_SKILLS oben. An
#     /home/agent/.claude/skills hängt sbx seinen eigenen Store. Ein `ln -sfn`
#     dorthin scheitert nicht etwa, sondern legt den Link STILL IN diesen Store
#     hinein. Skills kommen deshalb per Kopie hinein (copy_skills), nicht per
#     Link.
CLAUDE_LINKED=(agents commands rules plugins hooks output-styles workflows)

# --- Netz --------------------------------------------------------------------
#
# Die Sandbox darf standardmäßig NUR hierhin. Fehlt dir ein Host, ist das kein
# Fehler, sondern der Normalfall — `solobox allow <host>` gibt ihn frei, und
# EXTRA_HOSTS in der Konfiguration macht es dauerhaft.
#
# Jede Regel ist --sandbox-scoped. Das ist keine Förmlichkeit: `sbx ls` zeigt
# auf dieser Maschine weitere Sandboxes, die anderen Setups gehören. Eine
# globale Regel würde deren Policy mitverändern.
BASE_HOSTS=(
  api.anthropic.com                        # Claude selbst
  '*.anthropic.com'                        # Updates, Telemetrie, Statusseite
  '*.claude.ai'                            # Login und Connectors
  github.com                               # git clone / push
  '*.github.com'                           # gh, API
  '*.githubusercontent.com'                # Rohdateien, Plugin-Marktplätze
  '*.npmjs.org'                            # npm / pnpm
  '*.nodejs.org'                           # Node-Downloads
  pypi.org                                 # pip / uv / poetry
  files.pythonhosted.org                   # die eigentlichen Python-Pakete
  '*.astral.sh'                            # uv-Updates und Python-Interpreter
  '*.aikido.dev'                           # Safe-Chain-Prüfungen
  '*.playwright.dev'                       # Playwright
  playwright.download.prss.microsoft.com   # Browser-Downloads von Playwright
  '*.microsoft.com'                        # dito, je nach Region
  '*.context7.com'                         # context7-MCP
  '*.atlassian.com'                        # Atlassian-Plugin
  '*.atlassian.net'                        # deine Atlassian-Instanz
  '*.figma.com'                            # Figma-Plugin
  '*.docker.io'                            # Images ziehen
  ghcr.io                                  # GitHub Container Registry
  localhost                                # lokale Entwicklungsserver
)

# --- Kleine Helfer -----------------------------------------------------------

info() { printf '>> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

# Die Konfiguration ist optional — fehlt sie, gelten die Standardwerte oben.
# Sie ist ganz normales Bash und darf die Variablen einfach überschreiben.
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

require_tools() {
  local t
  for t in sbx docker; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' ist nicht installiert."
  done
}

sandbox_exists() { sbx ls -q 2>/dev/null | grep -qx "$SANDBOX"; }

hash_file()     { printf '%s\n' "$STATE_DIR/image.hash"; }
recorded_hash() { cat "$(hash_file)" 2>/dev/null || true; }
current_hash()  { shasum -a 256 "$DOCKERFILE" | cut -d' ' -f1; }

sandbox_image_file()     { printf '%s\n' "$STATE_DIR/sandbox.image"; }
recorded_sandbox_image() { cat "$(sandbox_image_file)" 2>/dev/null || true; }

# Die ID des Templates im sbx-Store — oder leer, wenn keins geladen ist.
# `sbx template load` stellt dem Namen "docker.io/" voran.
#
# Das `|| true` ist Notwendigkeit, keine Bequemlichkeit: `sbx template ls` endet
# mit Exitcode 1, solange man nicht bei Docker angemeldet ist. Wegen `pipefail`
# und `set -e` würde das Skript sonst stumm abbrechen. Eine leere Antwort ist
# hier die richtige Antwort.
template_id() {
  local repo="docker.io/${IMAGE%:*}" tag="${IMAGE##*:}"
  sbx template ls 2>/dev/null \
    | awk -v r="$repo" -v t="$tag" '$1==r && $2==t { print $3; exit }' || true
}

# Ein Pfad aus ROOTS ohne das ":ro"-Suffix.
root_path() { printf '%s\n' "${1%:ro}"; }

# Liegt $1 unter einem der beschreibbaren ROOTS? Gibt den passenden Wurzelpfad
# aus. Read-only-Wurzeln zählen mit — dort kann Claude lesen, nur nicht
# schreiben.
root_for() {
  local ziel="$1" eintrag pfad
  for eintrag in "${ROOTS[@]}"; do
    pfad="$(root_path "$eintrag")"
    # Der Schrägstrich am Ende verhindert, dass "/a/bc" als Treffer für "/a/b"
    # durchgeht.
    if [ "$ziel" = "$pfad" ] || [ "${ziel#"$pfad"/}" != "$ziel" ]; then
      printf '%s\n' "$pfad"
      return 0
    fi
  done
  return 1
}

# Kennt die installierte sbx-Version `--no-share-skills`? Unbekannte Flags
# meldet sbx mit "unknown flag", fehlende Pfade dagegen mit "requires at least".
# Wir fragen also ohne Pfad an: kommt die Pfad-Meldung, ist das Flag bekannt.
supports_no_share_skills() {
  ! sbx create claude --no-share-skills 2>&1 | grep -qi 'unknown flag'
}

# --- Woher weiß solobox, was gebaut werden muss? -----------------------------
#
# Alle folgenden Helfer lesen BEOBACHTBARE Tatsachen aus, keine Merkzettel. Der
# Unterschied ist nicht akademisch: Eine Merkdatei unter ~/.local/state kann
# fehlen, gelöscht werden oder auf einem zweiten Rechner nie existiert haben —
# und dann behauptet der Wrapper Dinge, die er nicht weiß.
#
# Jedes `|| true` steht da, weil ein fehlendes Image, ein nicht angemeldeter
# Docker oder eine gestoppte Sandbox NORMALE Zustände sind. Eine leere Antwort
# ist hier die richtige Antwort; die Aufrufer behandeln sie.

# Der Stempel, den das lokal gebaute Image trägt (siehe Dockerfile, ganz unten).
image_stamp() {
  docker image inspect "$IMAGE" \
    --format '{{index .Config.Labels "solobox.dockerfile-sha"}}' 2>/dev/null || true
}

# Der Basis-Image-Digest, gegen den zuletzt gebaut wurde.
image_base_digest() {
  docker image inspect "$IMAGE" \
    --format '{{index .Config.Labels "solobox.base-digest"}}' 2>/dev/null || true
}

# Die kurze ID des lokal gebauten Images. `sbx template ls` zeigt dieselbe ID,
# sobald das Image geladen ist — damit ist Ebene 2 ohne Merkdatei prüfbar.
local_image_id() {
  docker images --format '{{.ID}}' "$IMAGE" 2>/dev/null | head -n1 || true
}

# Der aktuelle Digest des Basis-Images in der Registry. Braucht Netz und ein paar
# Sekunden — deshalb nur auf Anforderung (`check --base`).
basis_digest() {
  docker buildx imagetools inspect "$BASE_IMAGE" \
    --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

# Antwortet der Docker-Daemon? "Kein Image" und "ich kann nicht nachsehen" sind
# zwei verschiedene Aussagen, und nur die erste rechtfertigt ein 'build'.
# `.Server.Version` fragt bewusst den DAEMON ab — die Client-Version antwortet
# auch dann, wenn Docker Desktop gar nicht läuft.
docker_erreichbar() {
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# Dasselbe für sbx. Eine leere Liste heißt "keine Sandbox", ein FEHLER heißt
# "ich weiß es nicht" (typisch: nicht bei Docker angemeldet). Ohne diese
# Unterscheidung würde ein fehlendes `sbx login` als "keine Sandbox vorhanden"
# durchgehen — und `up` wollte daraufhin eine zweite anlegen.
sbx_erreichbar() {
  sbx ls -q >/dev/null 2>&1
}

sandbox_running() {
  sbx ls 2>/dev/null | awk -v n="$SANDBOX" 'NR>1 && $1==n && $3=="running" { gefunden=1 } END { exit !gefunden }'
}

# Der Stempel der laufenden Sandbox. Bewusst NUR wenn sie läuft: `sbx exec`
# würde eine gestoppte Sandbox starten, und ein `status`, das im Hintergrund
# einen Container hochfährt, ist eine Überraschung, die niemand bestellt hat.
sandbox_stamp() {
  sandbox_running || return 0
  sbx exec "$SANDBOX" cat /etc/solobox-stamp 2>/dev/null | tr -d '\r\n' || true
}

# Die Workspaces, die die Sandbox TATSÄCHLICH eingehängt hat — inklusive ":ro".
#
# Warum `--json` und trotzdem kein jq? Weil jq auf dem Host nicht vorausgesetzt
# werden soll (dieselbe Begründung wie bei template_id). Die Ausgabe ist
# eingerückt und hat genau einen Workspace pro Zeile; awk schneidet den Block
# der eigenen Sandbox heraus und liest die Zeichenketten zwischen den
# Anführungszeichen.
aktuelle_mounts() {
  sbx ls --json 2>/dev/null | awk -v n="\"$SANDBOX\"" '
    $1 == "\"name\":" && $2 == n","      { treffer = 1 }
    treffer && $1 == "\"workspaces\":"   { drin = 1; next }
    drin && /\]/                         { exit }
    drin {
      gsub(/[",]/, "")                 # Anführungszeichen und Kommas weg
      gsub(/^[ \t]+|[ \t]+$/, "")      # Einrückung weg — sonst passt kein Vergleich
      if ($0 != "") print
    }
  ' || true
}

# --- build: Image bauen und als sbx-Template registrieren --------------------
#
# Warum der Umweg über eine tar-Datei? Der Docker-Daemon, den sbx benutzt, ist
# NICHT derselbe wie dein lokaler — er sieht deine lokal gebauten Images nicht.
# `docker save` + `sbx template load` schiebt das Image von dem einen in den
# anderen. Deshalb bewegt dieser Schritt mehrere Gigabyte und dauert.
cmd_build() {
  local now recorded
  now="$(current_hash)"
  recorded="$(recorded_hash)"

  if [ "$now" = "$recorded" ] && [ -n "$(template_id)" ] && [ "${1:-}" != "--force" ]; then
    info "Dockerfile unverändert und Template vorhanden — Bau übersprungen."
    info "Erzwingen: solobox build --force"
    return 0
  fi

  info "baue Image '$IMAGE' ..."
  # Die beiden Stempel wandern als Build-Argumente ins Image (siehe Dockerfile,
  # ganz unten). Daran erkennt `solobox check` später, woraus eine Sandbox
  # entstanden ist — ohne auf eine Merkdatei angewiesen zu sein.
  #
  # Der Basis-Digest ist eine Registry-Abfrage und darf scheitern (offline,
  # nicht angemeldet). Dann steht "unbekannt" im Image, und `check --base`
  # sagt das auch so, statt etwas zu behaupten.
  local basis
  basis="$(basis_digest)"
  [ -n "$basis" ] || basis="unbekannt"

  docker build -t "$IMAGE" -f "$DOCKERFILE" \
    --build-arg SOLOBOX_STAMP="$now" \
    --build-arg SOLOBOX_BASE_DIGEST="$basis" \
    "$SCRIPT_DIR"

  local tarball
  tarball="$(mktemp -t solobox-image.XXXXXX.tar)"
  info "exportiere das Image (mehrere GB, das dauert) ..."
  docker save "$IMAGE" -o "$tarball"
  info "Größe: $(du -h "$tarball" | cut -f1)"

  info "lade das Image in den sbx-Template-Store ..."
  sbx template load "$tarball"
  rm -f "$tarball"

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$now" > "$(hash_file)"
  info "fertig. Template '$IMAGE' steht bereit."
}

# --- Sandbox anlegen ---------------------------------------------------------
# Die vollständige Workspace-Liste, mit der die Sandbox angelegt WÜRDE — in
# genau der Reihenfolge, in der `sbx create` sie bekommt.
#
# Diese Funktion ist die EINZIGE Quelle dafür. `provision` legt danach an,
# `cmd_check` vergleicht damit gegen die tatsächlich eingehängte Liste. Zwei
# getrennte Listen wären eine Fehlerquelle, die man erst bemerkt, wenn ein
# Ordner monatelang fehlt.
#
# Nebenwirkung mit Absicht: fehlende ~/.claude-Unterordner werden angelegt. sbx
# bricht sonst beim Anlegen ab, und auf frisch eingerichteten Rechnern fehlt
# z.B. ~/.claude/workflows.
gewuenschte_mounts() {
  local d
  printf '%s\n' "${ROOTS[@]}"
  for d in "${CLAUDE_SHARED[@]}"; do
    mkdir -p "$HOME/.claude/$d"
    # Die Klammern um $d sind kein Zierrat: in zsh würde "$HOME/.claude/$d:ro"
    # als History-Modifier ":r" gelesen und ergäbe "…/agentso".
    printf '%s\n' "$HOME/.claude/${d}:ro"
  done
}

provision() {
  local mounts=() flags=() eintrag pfad

  # Vorab prüfen, statt sbx mitten im Anlegen scheitern zu lassen. sbx nimmt nur
  # Verzeichnisse; eine Datei quittiert es mit "workspace path exists but is not
  # a directory" — eine Meldung, die man erst nach dem zweiten Lesen versteht.
  for eintrag in "${ROOTS[@]}"; do
    pfad="$(root_path "$eintrag")"
    if [ ! -e "$pfad" ]; then
      die "ROOTS: '$pfad' existiert nicht. sbx würde das Anlegen verweigern."
    fi
    if [ ! -d "$pfad" ]; then
      die "ROOTS: '$pfad' ist eine Datei. sbx hängt nur VERZEICHNISSE ein.
       Eine einzelne Datei bringst du mit 'sbx cp' hinein — für die
       Git-Identität erledigt das solobox bereits selbst."
    fi
  done

  # Prozess-Substitution, keine Pipe: Eine Pipe steckte die Schleife in eine
  # Subshell, und das gefüllte Array wäre danach wieder leer.
  while IFS= read -r eintrag; do
    mounts+=("$eintrag")
  done < <(gewuenschte_mounts)

  if [ "$ISOLATE_SKILLS" = "1" ]; then
    if supports_no_share_skills; then
      info "ISOLATE_SKILLS=1 — die Sandbox bekommt einen EIGENEN Skill-Store."
      flags+=(--no-share-skills)
    else
      warn "ISOLATE_SKILLS=1 verlangt '--no-share-skills', aber diese sbx-Version"
      warn "kennt das Flag nicht. Ohne das Flag landen deine globalen Skills im"
      warn "Store, den sich ALLE Sandboxes dieser Maschine teilen."
      local antwort
      read -r -p "Trotzdem anlegen? [j/N] " antwort
      case "$antwort" in
        [jJyY]*) info "gut — weiter mit geteiltem Store." ;;
        *) die "abgebrochen." ;;
      esac
    fi
  fi

  info "lege Sandbox '$SANDBOX' aus Template '$IMAGE' an ..."
  info "Wurzeln: ${ROOTS[*]}"
  sbx create ${flags[@]+"${flags[@]}"} -t "$IMAGE" --name "$SANDBOX" claude \
    "${mounts[@]}"

  # Festhalten, aus welchem Template diese Sandbox entstanden ist — `sbx ls`
  # verrät es nicht, und `status`/`update` brauchen es. Ein neu gebautes
  # Template erreicht eine BESTEHENDE Sandbox nämlich nicht: Container werden
  # beim Anlegen kopiert, nicht laufend angeglichen.
  mkdir -p "$STATE_DIR"
  template_id > "$(sandbox_image_file)"
}

# --- Netzregeln --------------------------------------------------------------
apply_network() {
  info "setze Netzwerkregeln für '$SANDBOX' ..."
  local host
  for host in "${BASE_HOSTS[@]}" ${EXTRA_HOSTS[@]+"${EXTRA_HOSTS[@]}"}; do
    # "Already covered in policy" ist ab dem zweiten Start der Normalfall und
    # kein Fehler — deshalb aus der Ausgabe gefiltert.
    sbx policy allow network --sandbox "$SANDBOX" "$host" 2>&1 \
      | grep -vF 'Already covered in policy' || true
  done
}

# --- Globale Konfiguration verlinken -----------------------------------------
#
# Warum Symlinks? Zusätzliche Workspaces landen in der Sandbox unter ihrem
# absoluten HOST-Pfad — also /Users/du/.claude/agents. Claude sucht seine
# Agents aber unter /home/agent/.claude/agents. Der Link verbindet beides.
#
# Die Prüfung "ist das Ziel schon ein echtes Verzeichnis?" sichert gegen den
# Fall ab, dass sbx dort selbst etwas eingehängt hat: dann würde `ln -sfn` den
# Link stillschweigend HINEIN legen statt das Verzeichnis zu ersetzen.
link_shared_config() {
  info "verlinke globale Agents/Commands/Rules/Plugins/Hooks ..."
  local dirs="${CLAUDE_LINKED[*]}"
  sbx exec -d "$SANDBOX" bash -c "
    set -u
    mkdir -p \"\$HOME/.claude\"
    for d in $dirs; do
      quelle='$HOME/.claude/'\$d
      ziel=\"\$HOME/.claude/\$d\"
      [ -d \"\$quelle\" ] || continue
      if [ -d \"\$ziel\" ] && [ ! -L \"\$ziel\" ]; then
        echo \"Hinweis: \$ziel ist ein echtes Verzeichnis (von sbx eingehaengt) — uebersprungen.\" >&2
        continue
      fi
      ln -sfn \"\$quelle\" \"\$ziel\"
    done
  "
}

# --- Skills hineinkopieren ---------------------------------------------------
#
# Skills können NICHT verlinkt werden (siehe CLAUDE_LINKED). Also kopieren wir
# sie bei jedem `up` neu — das ist zugleich der Weg, auf dem neue Skills vom
# Host in die laufende Sandbox kommen.
#
# Warum tar und nicht `cp -r`? Ist ein Skill-Ordner auf dem Host
# schreibgeschützt (555), legt `cp` das Zielverzeichnis mit denselben Rechten an
# und kann anschließend nichts mehr hineinschreiben — der Skill fehlt dann, und
# zwar mit einer Meldung, die nach einer Lappalie aussieht. tar setzt die Rechte
# der Zielverzeichnisse erst zum Schluss und schreibt deshalb sauber hinein.
copy_skills() {
  info "kopiere globale Skills in die Sandbox ..."
  # Die einfachen Anführungszeichen sind Absicht: $1 und $HOME sollen NICHT hier
  # auf dem Host expandieren, sondern erst in der Sandbox.
  # shellcheck disable=SC2016
  sbx exec "$SANDBOX" bash -c '
    set -uo pipefail
    quelle="$1/.claude/skills"
    ziel="$HOME/.claude/skills"
    [ -d "$quelle" ] || exit 0
    mkdir -p "$ziel"
    ( cd "$quelle" && tar cf - . ) | ( cd "$ziel" && tar xf - --no-same-permissions )
    printf "kopiert: %s Skill-Ordner\n" "$(find "$ziel" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d " ")"
  ' _ "$HOME" || warn "Skills konnten nicht kopiert werden — die Sandbox läuft trotzdem."
}

# --- settings.json ableiten --------------------------------------------------
#
# Die settings.json des Hosts wird NICHT gemountet: sie enthält Berechtigungen
# und Pfade, die für deinen Host gelten, dazu einen kompletten sandbox-Block.
# Stattdessen leiten wir eine eigene Datei ab und übernehmen genau das, was in
# einem Container Sinn ergibt.
#
# Warum python3 statt jq auf dem Host? Weil wir ohnehin IN der Sandbox rechnen,
# wo Python garantiert vorhanden ist — und der Host nichts zusätzlich braucht.
SETTINGS_PY='
import json, pathlib, sys

quelle = pathlib.Path("/tmp/solobox-host-settings.json")
modus = sys.argv[1]
skip = set(sys.argv[2:])

host = json.loads(quelle.read_text()) if quelle.exists() else {}

ziel = pathlib.Path.home() / ".claude" / "settings.json"
cfg = json.loads(ziel.read_text()) if ziel.exists() else {}

# 1:1 übernommen — das sind Einstellungen, die nichts über den Host verraten.
for key in ("enabledPlugins", "extraKnownMarketplaces", "model", "effortLevel"):
    if key in host:
        cfg[key] = host[key]

# Hooks: übernehmen, aber die gesperrten Ereignisse weglassen.
hooks = {k: v for k, v in host.get("hooks", {}).items() if k not in skip}
if hooks:
    cfg["hooks"] = hooks
uebersprungen = sorted(set(host.get("hooks", {})) & skip)

# Berechtigungen: NEU GESETZT statt kopiert (die des Hosts gelten für den Host).
#
# Der Haken, den man nur beim Hineinsehen findet: Das Image hinterlässt seinen
# Modus auf der OBERSTEN Ebene der Datei ("defaultMode": "bypassPermissions",
# dazu "bypassPermissionsModeAccepted"). Dokumentiert ist dagegen
# "permissions.defaultMode". Die Datei behauptet damit zweierlei, und welche
# Angabe gewinnt, steht nirgends.
#
# Deshalb bleibt genau eine stehen: bei allem außer bypassPermissions die
# Schlüssel des Images entfernen, bei bypassPermissions beide Ebenen
# gleichlautend setzen. So sagt die Datei in jedem Fall nur noch eines.
#
# (Nicht per --print prüfbar: der Kopfmodus setzt Berechtigungen gar nicht
# durch. Ob Bash in der interaktiven Sitzung nachfragt, zeigt nur diese.)
cfg.setdefault("permissions", {})["defaultMode"] = modus
if modus == "bypassPermissions":
    cfg["defaultMode"] = modus
    cfg["bypassPermissionsModeAccepted"] = True
else:
    cfg.pop("defaultMode", None)
    cfg.pop("bypassPermissionsModeAccepted", None)

ziel.parent.mkdir(parents=True, exist_ok=True)
ziel.write_text(json.dumps(cfg, indent=2) + "\n")

print("Hooks aktiv: " + (", ".join(sorted(hooks)) or "keine"))
if uebersprungen:
    print("Hooks uebersprungen (HOOK_SKIP): " + ", ".join(uebersprungen))
print("Plugins aktiviert: " + str(len(cfg.get("enabledPlugins", {}))))
print("Berechtigungsmodus: " + modus)
'

apply_settings() {
  local quelle="$HOME/.claude/settings.json"

  case "$PERMISSION_MODE" in
    acceptEdits | default | plan | bypassPermissions) ;;
    *) die "PERMISSION_MODE='$PERMISSION_MODE' ist unbekannt.
       Erlaubt: acceptEdits, default, plan, bypassPermissions." ;;
  esac

  if [ ! -f "$quelle" ]; then
    info "keine globale settings.json gefunden — nichts abzuleiten."
    return 0
  fi

  info "leite settings.json für die Sandbox ab ..."
  # Der Umweg über /tmp, weil die Datei bewusst NICHT gemountet ist.
  if ! sbx cp "$quelle" "$SANDBOX:/tmp/solobox-host-settings.json"; then
    warn "settings.json ließ sich nicht in die Sandbox kopieren — übersprungen."
    return 0
  fi
  sbx exec "$SANDBOX" python3 -c "$SETTINGS_PY" "$PERMISSION_MODE" ${HOOK_SKIP[@]+"${HOOK_SKIP[@]}"} \
    || warn "settings.json konnte nicht abgeleitet werden — die Sandbox läuft trotzdem."
}

# --- Git-Identität ------------------------------------------------------------
#
# Ohne user.name/user.email committet der Agent als "agent@<container-id>" — oder
# git verweigert den Commit ganz. Die naheliegende Lösung wäre, ~/.gitconfig
# einzuhängen. Das geht NICHT: sbx nimmt als Workspace nur Verzeichnisse, keine
# einzelnen Dateien.
#
# Also übertragen wir nur die zwei Werte, auf die es ankommt. Das ist sogar das
# sauberere Vorgehen: eine echte ~/.gitconfig enthält oft Aliase, `includeIf`-
# Blöcke und Pfade zu Credential-Helfern des Hosts, die im Container ins Leere
# zeigen.
apply_git_identity() {
  local name email
  name="$(git config --global --get user.name 2>/dev/null || true)"
  email="$(git config --global --get user.email 2>/dev/null || true)"

  if [ -z "$name" ] && [ -z "$email" ]; then
    info "keine globale Git-Identität auf dem Host — übersprungen."
    return 0
  fi

  info "übernehme Git-Identität ($name <$email>) ..."
  # Argumente nach `-c` landen in $1/$2 — das erspart Anführungszeichen-Ebenen
  # bei Namen mit Leerzeichen.
  # shellcheck disable=SC2016
  sbx exec -d "$SANDBOX" bash -c '
    [ -n "$1" ] && git config --global user.name  "$1"
    [ -n "$2" ] && git config --global user.email "$2"
    exit 0
  ' _ "$name" "$email" || warn "Git-Identität ließ sich nicht setzen."
}

# --- MCP-Server laden --------------------------------------------------------
#
# Zwei Wege, und beide brauchen freigeschaltete Hosts:
#
#   1. Über deine Plugins. Bringt ein Plugin einen MCP-Server mit, ist er
#      da, sobald das Plugin aktiv ist (siehe apply_settings) — hier ist
#      nichts zu tun.
#   2. Über `sbx mcp add` auf dem HOST registrierte Server. Sie laufen
#      außerhalb der Sandbox, sbx reicht sie über sein Gateway hinein. Das ist
#      der Weg für alles mit OAuth-Anmeldung: der Anmeldeflow passiert einmal
#      auf dem Host.
load_mcp() {
  local server
  for server in ${MCP_SERVERS[@]+"${MCP_SERVERS[@]}"}; do
    info "lade MCP-Server '$server' ..."
    sbx mcp load "$server" --sandbox "$SANDBOX" \
      || warn "'$server' ließ sich nicht laden. 'sbx mcp ls' zeigt die registrierten Server."
  done
}

# --- sync: alles Nachträgliche in die laufende Sandbox bringen ---------------
#
# Genau die Schritte, die `up` vor dem Start ausführt — nur ohne Start. Nützlich,
# wenn du auf dem Host einen Skill ergänzt oder ein Plugin installiert hast und
# das in die laufende Sandbox nachziehen willst, ohne sie neu anzulegen.
cmd_sync() {
  sandbox_exists || die "Sandbox '$SANDBOX' existiert nicht. Erst 'solobox up'."
  apply_network
  link_shared_config
  copy_skills
  apply_settings
  apply_git_identity
  load_mcp
  info "fertig. Neue Skills und Plugins sieht Claude nach einem Neustart der Sitzung."
}

# --- up: der Hauptweg --------------------------------------------------------
cmd_up() {
  local ziel="${1:-$(pwd -P)}"
  [ -d "$ziel" ] || die "'$ziel' ist kein Verzeichnis."
  ziel="$(cd "$ziel" && pwd -P)"

  # Ohne Template geht nichts — und statt zu meckern, bauen wir es beim ersten
  # Mal einfach.
  # Ohne Template geht nichts — statt zu meckern, bauen wir es beim ersten Mal.
  if [ -z "$(template_id)" ]; then
    info "kein Template '$IMAGE' im sbx-Store — ich baue es jetzt."
    cmd_build
  fi

  # Der Stand-Check, bevor irgendetwas startet. Er beantwortet in einem Aufwasch
  # die vier Fragen, die man sonst einzeln übersieht — vor allem die, ob die
  # bestehende Sandbox überhaupt noch zu ROOTS und CLAUDE_SHARED passt.
  local stufe=0
  pruefe_stand >/dev/null || true
  stufe="$STUFE"

  if [ "$stufe" -ge 3 ] && sandbox_exists; then
    echo
    warn "Die bestehende Sandbox passt nicht mehr zum aktuellen Stand:"
    pruefe_stand "" "   "
    echo
    warn "Das Angleichen verlangt ein Neuanlegen. Dabei gehen verloren:"
    warn "  - der Claude-Login"
    warn "  - zur Laufzeit installierte Pakete"
    warn "  - Änderungen an /etc/sandbox-persistent.sh"
    warn "Deine Projektdateien liegen auf dem Host und bleiben unberührt."
    local antwort
    read -r -p "Sandbox jetzt neu anlegen? [j/N] " antwort
    case "$antwort" in
      [jJyY]*)
        info "entferne und lege neu an ..."
        sbx rm --force "$SANDBOX"
        rm -f "$(sandbox_image_file)"
        ;;
      *)
        warn "gut — ich starte die bestehende Sandbox. Die Änderung gilt darin NICHT."
        ;;
    esac
  elif [ "$stufe" -eq 2 ]; then
    warn "Das Dockerfile ist neuer als das Template — 'solobox update'."
    warn "Die Sandbox startet solange auf dem alten Stand ('solobox check' zeigt Details)."
  fi

  local frisch=0
  if ! sandbox_exists; then
    provision
    frisch=1
  fi

  apply_network
  link_shared_config
  copy_skills
  apply_settings
  apply_git_identity
  load_mcp

  # Beim allerersten Start gehen wir über `sbx run` — den von sbx vorgesehenen
  # Weg, den Agenten zu starten. Dort meldest du dich einmal bei Claude an.
  if [ "$frisch" = "1" ]; then
    info "erster Start — hier meldest du dich einmal bei Claude an."
    info "Danach startet 'solobox up' Claude direkt im jeweiligen Projekt."
    # ⚠️  Diese eine Sitzung läuft anders als alle folgenden: `sbx run` startet
    #     den Agenten mit `--dangerously-skip-permissions` (nachgemessen mit
    #     `ps` in der Sandbox). Damit ist PERMISSION_MODE hier wirkungslos.
    #     Ab dem zweiten Start geht es über `sbx exec`, ohne dieses Flag.
    warn "Hinweis: sbx startet den Agenten hier mit abgeschalteten"
    warn "Berechtigungen (--dangerously-skip-permissions). PERMISSION_MODE"
    warn "($PERMISSION_MODE) gilt ab dem nächsten 'solobox up'."
    sbx run --name "$SANDBOX" claude
    return 0
  fi

  # Ab jetzt der eigentliche Trick dieser Variante: Claude wird IM PROJEKT
  # gestartet. Weil Workspaces unter ihrem absoluten Host-Pfad eingehängt sind,
  # ist der Pfad auf dem Host derselbe wie in der Sandbox — "-w" trifft also.
  if root_for "$ziel" >/dev/null; then
    info "starte Claude in '$ziel' ..."
    sbx exec -it -w "$ziel" "$SANDBOX" claude
  else
    warn "'$ziel' liegt unter keiner der Wurzeln (${ROOTS[*]})."
    warn "Die Sandbox sieht diesen Ordner nicht — ich starte im Primary Workspace."
    warn "Soll der Ordner dazu, muss die Sandbox neu angelegt werden:"
    warn "  ROOTS in $CONFIG_FILE ergänzen, dann 'solobox rm' und 'solobox up'."
    sbx run --name "$SANDBOX" claude
  fi
}

# --- check: muss etwas neu gebaut oder neu angelegt werden? ------------------
#
# Die Frage „muss ich neu bauen?" hat vier Ursachen, und sie kosten sehr
# unterschiedlich viel. Der Sinn dieses Kommandos ist nicht, irgendetwas zu
# melden, sondern die BILLIGSTE ausreichende Maßnahme zu nennen:
#
#   Stufe 1  sync    Sekunden — neue Skills, Plugins, Hooks, MCP-Server
#   Stufe 2  build   Minuten  — das Dockerfile hat sich geändert
#   Stufe 3  rm+up   teuer    — kostet den Claude-Login und Laufzeitpakete
#
# Der Exitcode ist die höchste nötige Stufe (0 = alles aktuell). Damit lässt
# sich der Check auch in einem Skript oder in der CI benutzen.
#
# Wird von `status`, `doctor` und `up` mitbenutzt — es soll nur EINE Wahrheit
# geben, nicht drei Stellen, die dasselbe unterschiedlich beantworten.
STUFE=0
PRAEFIX=""

# ⚠️  Warum die Einrückung ein PARAMETER ist und keine Pipe:
#     `pruefe_stand | sed 's/^/  /'` sieht harmlos aus, steckt die Funktion aber
#     in eine Subshell — und dann ist $STUFE beim Aufrufer wieder 0. Dasselbe
#     gilt für `$(pruefe_stand)`. Beim Bauen dieses Kommandos genau so
#     hineingelaufen: Die Befunde stimmten, der Exitcode war immer 0.
zeile() { printf '%s%s\n' "$PRAEFIX" "$*"; }

# Eine Befundzeile ausgeben und dabei die nötige Stufe anheben. Die Stufe kann
# nur steigen — der teuerste Befund gewinnt.
#
# Das `|| true` ist nötig, nicht kosmetisch: Unter `set -e` gilt ein `[ … ]`,
# das am Ende einer Funktion nicht zutrifft, als fehlgeschlagenes Kommando und
# würde das Skript beenden.
melde() {
  local stufe="$1" zeichen="$2" text="$3"
  [ "$stufe" -gt "$STUFE" ] && STUFE="$stufe" || true
  printf '%s  %s %s\n' "$PRAEFIX" "$zeichen" "$text"
}

pruefe_stand() {
  local mit_basis="${1:-}"
  PRAEFIX="${2:-}"
  STUFE=0

  local dockerfile_hash stempel_image image_id template
  dockerfile_hash="$(current_hash)"

  local docker_antwortet=1
  docker_erreichbar || docker_antwortet=0

  stempel_image="$(image_stamp)"
  image_id="$(local_image_id)"
  template="$(template_id)"

  zeile "--- 1. Lokales Image gegen Dockerfile ---"
  if [ "$docker_antwortet" -eq 0 ]; then
    melde 0 "·" "Docker antwortet nicht — übersprungen (läuft Docker Desktop?)"
  elif [ -z "$image_id" ]; then
    melde 2 "✗" "kein lokales Image '$IMAGE' — 'solobox build'"
  elif [ -z "$stempel_image" ] || [ "$stempel_image" = "unbekannt" ]; then
    melde 2 "·" "Image trägt keinen Stempel (vor dieser solobox-Version gebaut)"
    zeile "      Ein 'solobox build --force' bringt ihn an."
  elif [ "$stempel_image" = "$dockerfile_hash" ]; then
    melde 0 "✓" "Image ist auf dem Stand des Dockerfiles"
  else
    melde 2 "✗" "Dockerfile hat sich geändert — 'solobox build'"
  fi

  zeile "--- 2. Template im sbx-Store ---"
  if [ -z "$template" ]; then
    melde 2 "✗" "kein Template '$IMAGE' im Store — 'solobox build'"
    zeile "      (Oder du bist nicht angemeldet: 'sbx login'. Beides sieht gleich aus.)"
  elif [ -z "$image_id" ]; then
    # Template ist da, aber der lokale Bau lässt sich nicht abfragen — dann ist
    # "entspricht dem lokalen Image" eine Behauptung, nicht ein Befund.
    melde 0 "·" "Template vorhanden ($template); lokales Image nicht abfragbar"
  elif [ "$template" != "$image_id" ]; then
    melde 2 "✗" "Store hat ein anderes Image ($template) als der lokale Bau ($image_id)"
    zeile "      Das lokale Image wurde gebaut, aber nicht geladen — 'solobox build'."
  else
    melde 0 "✓" "Template im Store entspricht dem lokalen Image"
  fi

  local sbx_antwortet=1
  sbx_erreichbar || sbx_antwortet=0

  zeile "--- 3. Sandbox gegen Template ---"
  if [ "$sbx_antwortet" -eq 0 ]; then
    melde 0 "·" "sbx antwortet nicht — übersprungen (angemeldet? 'sbx login')"
  elif ! sandbox_exists; then
    melde 0 "·" "keine Sandbox vorhanden — 'solobox up' legt sie aus dem aktuellen Template an"
  else
    local stempel_sandbox
    stempel_sandbox="$(sandbox_stamp)"
    if [ -n "$stempel_sandbox" ]; then
      if [ "$stempel_sandbox" = "$dockerfile_hash" ]; then
        melde 0 "✓" "Sandbox läuft auf dem aktuellen Dockerfile"
      else
        melde 3 "✗" "Sandbox läuft auf einem ÄLTEREN Image — 'solobox rm && solobox up'"
      fi
    elif ! sandbox_running; then
      melde 0 "·" "Sandbox gestoppt — Stempel nicht lesbar, ohne sie zu starten"
      zeile "      Prüfe es nach dem nächsten Start, oder: sbx exec solobox cat /etc/solobox-stamp"
    else
      # Läuft, hat aber keinen Stempel: aus einem Image ohne Stempel angelegt.
      local vermerk; vermerk="$(recorded_sandbox_image)"
      if [ -n "$vermerk" ] && [ -n "$template" ] && [ "$vermerk" != "$template" ]; then
        melde 3 "✗" "Sandbox stammt aus Template $vermerk, im Store liegt $template"
      else
        melde 0 "·" "Sandbox trägt keinen Stempel (vor dieser solobox-Version angelegt)"
      fi
    fi
  fi

  zeile "--- 4. Mounts gegen Konfiguration ---"
  if [ "$sbx_antwortet" -eq 0 ]; then
    zeile "  · sbx antwortet nicht — übersprungen"
  elif ! sandbox_exists; then
    zeile "  · keine Sandbox — nichts zu vergleichen"
  else
    local soll ist fehlend ueberzaehlig
    soll="$(gewuenschte_mounts | sort)"
    ist="$(aktuelle_mounts | sort)"
    if [ -z "$ist" ]; then
      melde 0 "·" "Mounts nicht lesbar (sbx ls --json) — übersprungen"
    else
      fehlend="$(comm -23 <(printf '%s\n' "$soll") <(printf '%s\n' "$ist"))"
      ueberzaehlig="$(comm -13 <(printf '%s\n' "$soll") <(printf '%s\n' "$ist"))"
      if [ -z "$fehlend" ] && [ -z "$ueberzaehlig" ]; then
        melde 0 "✓" "eingehängte Ordner entsprechen der Konfiguration"
      else
        melde 3 "✗" "Sandbox passt nicht zur Konfiguration — 'solobox rm && solobox up'"
        # Mehrzeilige Listen mit sed einrücken statt mit Wortauftrennung im
        # printf — sonst zerlegt ein Leerzeichen im Pfad die Ausgabe.
        local eintrag
        for eintrag in $fehlend; do zeile "      fehlt in der Sandbox:  $eintrag"; done
        for eintrag in $ueberzaehlig; do zeile "      übrig in der Sandbox: $eintrag"; done
        zeile "      Grund: Workspaces sind nur beim Anlegen setzbar."
      fi
    fi
  fi

  if [ "$mit_basis" = "--base" ]; then
    zeile "--- 5. Basis-Image in der Registry ---"
    local gebaut aktuell
    gebaut="$(image_base_digest)"
    aktuell="$(basis_digest)"
    if [ -z "$aktuell" ]; then
      melde 0 "·" "Registry nicht erreichbar — übersprungen"
    elif [ -z "$gebaut" ] || [ "$gebaut" = "unbekannt" ]; then
      melde 0 "·" "Image hält den Basis-Digest nicht fest (älterer Bau)"
    elif [ "$gebaut" = "$aktuell" ]; then
      melde 0 "✓" "Basis-Image unverändert"
    else
      melde 2 "!" "Basis-Image hat sich bewegt — 'docker build --pull' bzw. 'solobox update'"
      zeile "      gebaut gegen: $gebaut"
      zeile "      jetzt aktuell: $aktuell"
    fi
  fi

  return 0
}

cmd_check() {
  local mit_basis=""
  case "${1:-}" in
    "") ;;
    --base) mit_basis="--base" ;;
    *) die "Unbekannte Option '$1'. Erlaubt: --base" ;;
  esac

  pruefe_stand "$mit_basis"

  echo
  case "$STUFE" in
    0) info "Alles aktuell — nichts zu tun." ;;
    1) info "Es genügt: solobox sync" ;;
    2) warn "Neu bauen nötig: solobox build   (danach ggf. 'solobox rm && solobox up')" ;;
    3) warn "Neu anlegen nötig: solobox rm && solobox up"
       warn "Das kostet den Claude-Login und zur Laufzeit installierte Pakete."
       warn "Deine Projektdateien liegen auf dem Host und bleiben unberührt." ;;
  esac
  return "$STUFE"
}

# --- Weitere Kommandos -------------------------------------------------------

cmd_shell() {
  sandbox_exists || die "Sandbox '$SANDBOX' existiert nicht. Erst 'solobox up'."
  local ziel="${1:-$(pwd -P)}"
  if root_for "$ziel" >/dev/null 2>&1; then
    sbx exec -it -w "$ziel" "$SANDBOX" bash
  else
    sbx exec -it "$SANDBOX" bash
  fi
}

cmd_allow() {
  local host="${1:-}"
  [ -n "$host" ] || die "Aufruf: solobox allow <host>"
  sbx policy allow network --sandbox "$SANDBOX" "$host"
  info "'$host' für '$SANDBOX' freigegeben."
  info "Dauerhaft wird es als EXTRA_HOSTS in $CONFIG_FILE."
}

cmd_rm() {
  warn "Das Entfernen von '$SANDBOX' löscht den Zustand IN der Sandbox:"
  warn "  - zur Laufzeit installierte Pakete"
  warn "  - den Claude-Login (du musst dich neu anmelden)"
  warn "  - Änderungen an /etc/sandbox-persistent.sh"
  warn "Deine Projektdateien liegen auf dem Host und sind NICHT betroffen."
  local antwort
  read -r -p "Sandbox '$SANDBOX' wirklich entfernen? [j/N] " antwort
  case "$antwort" in
    [jJyY]*)
      sbx rm --force "$SANDBOX"
      rm -f "$(sandbox_image_file)"
      info "entfernt."
      ;;
    *) info "abgebrochen." ;;
  esac
}

# --- status: was läuft, mit welchen Wurzeln, und wer teilt den Skill-Store ---
cmd_status() {
  echo "--- Die Sandbox ---"
  if sandbox_exists; then
    local zustand
    zustand="$(sbx ls 2>/dev/null | awk -v n="$SANDBOX" 'NR>1 && $1==n { print $3; exit }' || true)"
    printf '  %-10s %s\n' "$SANDBOX" "${zustand:-?}"

    # Die Wurzeln stehen hier, weil sie NUR beim Anlegen gesetzt wurden — nach
    # ein paar Wochen weiß niemand mehr auswendig, was die Sandbox sieht.
    echo "  Eingehängt:"
    aktuelle_mounts | sed 's/^/    /'
  else
    echo "  (keine — 'solobox up' im gewünschten Projekt)"
  fi

  # Ein und dieselbe Prüfung wie in `check`, `doctor` und `up`. Drei Stellen,
  # die dasselbe unterschiedlich beantworten, wären schlimmer als gar keine.
  echo "--- Stand (wie 'solobox check') ---"
  pruefe_stand "" "  "
  case "$STUFE" in
    0) echo "  → alles aktuell" ;;
    1) echo "  → 'solobox sync' genügt" ;;
    2) echo "  → 'solobox build' nötig" ;;
    3) echo "  → 'solobox rm && solobox up' nötig" ;;
  esac

  echo "--- MCP-Server (auf dem Host registriert) ---"
  sbx mcp ls 2>&1 | sed 's/^/  /' || true

  # Kein Selbstzweck: Solange ISOLATE_SKILLS=0 ist, schreiben wir deine globalen
  # Skills in einen Store, den sich diese Sandboxes mit dir teilen.
  echo "--- Andere Sandboxes auf dieser Maschine ---"
  local fremde
  fremde="$(sbx ls -q 2>/dev/null | grep -vx "$SANDBOX" || true)"
  if [ -n "$fremde" ]; then
    printf '%s\n' "$fremde" | sed 's/^/  /'
    if [ "$ISOLATE_SKILLS" = "1" ]; then
      echo "  → ISOLATE_SKILLS=1: eigener Skill-Store, diese sehen deine Skills NICHT."
    else
      echo "  → ISOLATE_SKILLS=0: geteilter Skill-Store — diese sehen deine globalen Skills."
    fi
  else
    echo "  keine"
  fi

  echo
  echo "Netzregeln ansehen: sbx policy ls $SANDBOX"
}

# --- update: neu bauen und sagen, was das der Sandbox NICHT bringt -----------
cmd_update() {
  cmd_build --force

  local aktuell vermerk
  aktuell="$(template_id)"
  echo
  if [ -z "$aktuell" ]; then
    warn "Template-ID nicht lesbar — überspringe den Abgleich."
    warn "Prüfe 'sbx login' und danach 'solobox status'."
    return 0
  fi

  if ! sandbox_exists; then
    info "Keine Sandbox vorhanden — das neue Template wird beim nächsten"
    info "'solobox up' verwendet."
    return 0
  fi

  vermerk="$(recorded_sandbox_image)"
  if [ -n "$vermerk" ] && [ "$vermerk" = "$aktuell" ]; then
    info "Die Sandbox läuft bereits auf diesem Template."
    return 0
  fi

  warn "Ein neues Template erreicht die bestehende Sandbox NICHT. Sie wurde beim"
  warn "Anlegen aus dem alten Template kopiert und bleibt darauf. Damit sie das"
  warn "neue bekommt, muss sie einmal neu angelegt werden:"
  warn ""
  warn "    solobox rm && solobox up"
  warn ""
  warn "Das kostet den Claude-Login und zur Laufzeit installierte Pakete."
  warn "Deine Projektdateien liegen auf dem Host und bleiben unberührt."
}

# --- install: den Aufruf auf den PATH legen ----------------------------------
#
# solobox wird IM PROJEKT aufgerufen — ein relativer Pfad ins Repo wäre dort
# unbrauchbar. Der Symlink zeigt ins Repo: bleibt das Repo, wo es ist, ist alles
# gut; wird es verschoben, meldet `doctor` den toten Link.
cmd_install() {
  mkdir -p "$(dirname "$BIN_LINK")"
  if [ -e "$BIN_LINK" ] && [ ! -L "$BIN_LINK" ]; then
    die "'$BIN_LINK' existiert und ist kein Symlink — ich fasse es nicht an."
  fi
  ln -sfn "$SCRIPT_PATH" "$BIN_LINK"
  info "verlinkt: $BIN_LINK -> $SCRIPT_PATH"
  case ":$PATH:" in
    *":$(dirname "$BIN_LINK"):"*)
      info "Der Ordner liegt auf dem PATH — 'solobox up' funktioniert ab sofort überall." ;;
    *)
      warn "$(dirname "$BIN_LINK") liegt NICHT auf dem PATH. Ergänze in deiner Shell:"
      warn "  export PATH=\"$(dirname "$BIN_LINK"):\$PATH\"" ;;
  esac
}

cmd_doctor() {
  local ok=0 t d
  echo "--- Werkzeuge auf dem Host ---"
  for t in sbx docker git gh; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '  ✓ %-6s %s\n' "$t" "$(command -v "$t")"
    else
      printf '  ✗ %-6s fehlt\n' "$t"; [ "$t" = "gh" ] || ok=1
    fi
  done

  echo "--- Aufruf ---"
  if [ -L "$BIN_LINK" ]; then
    local ziel; ziel="$(readlink "$BIN_LINK")"
    if [ "$ziel" = "$SCRIPT_PATH" ]; then
      printf '  ✓ %s -> %s\n' "$BIN_LINK" "$ziel"
    else
      printf '  ! %s zeigt auf %s (nicht auf dieses Skript)\n' "$BIN_LINK" "$ziel"
    fi
  else
    printf '  · %s fehlt — "solobox install" legt ihn an\n' "$BIN_LINK"
  fi

  echo "--- Stand von Image, Template und Sandbox ---"
  pruefe_stand "" "  "
  [ "$STUFE" -eq 0 ] || ok=1

  echo "--- Konfiguration ---"
  if [ -f "$CONFIG_FILE" ]; then
    echo "  ✓ $CONFIG_FILE"
  else
    echo "  · keine Konfiguration — es gelten die Standardwerte:"
    printf '      ROOTS=%s\n' "${ROOTS[*]}"
    printf '      HOOK_SKIP=%s\n' "${HOOK_SKIP[*]}"
    printf '      PERMISSION_MODE=%s\n' "$PERMISSION_MODE"
    printf '      ISOLATE_SKILLS=%s\n' "$ISOLATE_SKILLS"
  fi

  echo "--- Wurzeln ---"
  local eintrag pfad
  for eintrag in "${ROOTS[@]}"; do
    pfad="$(root_path "$eintrag")"
    if [ -d "$pfad" ]; then
      printf '  ✓ %s\n' "$eintrag"
    elif [ -e "$pfad" ]; then
      # sbx: "workspace path exists but is not a directory" — eine Datei als
      # Workspace lehnt es ab.
      printf '  ✗ %s ist eine Datei — sbx hängt nur Verzeichnisse ein\n' "$pfad"; ok=1
    else
      printf '  ✗ %s existiert nicht — sbx würde das Anlegen verweigern\n' "$pfad"; ok=1
    fi
  done

  echo "--- Git-Identität (wird in die Sandbox übernommen) ---"
  local gname gmail
  gname="$(git config --global --get user.name 2>/dev/null || true)"
  gmail="$(git config --global --get user.email 2>/dev/null || true)"
  if [ -n "$gname" ] || [ -n "$gmail" ]; then
    printf '  ✓ %s <%s>\n' "$gname" "$gmail"
  else
    echo "  · keine gesetzt — Commits aus der Sandbox hätten keinen Autor"
    echo "    git config --global user.name \"Dein Name\""
  fi

  echo "--- Geteilte Claude-Ordner ---"
  for d in "${CLAUDE_SHARED[@]}"; do
    if [ -d "$HOME/.claude/$d" ]; then
      printf '  ✓ ~/.claude/%-13s (%s Einträge)\n' "$d" \
        "$(find "$HOME/.claude/$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
    else
      printf '  · ~/.claude/%-13s fehlt — wird beim nächsten "up" angelegt\n' "$d"
    fi
  done

  if [ "$ISOLATE_SKILLS" = "1" ]; then
    echo "--- ISOLATE_SKILLS ---"
    if supports_no_share_skills; then
      echo "  ✓ diese sbx-Version kennt '--no-share-skills'"
    else
      echo "  ✗ diese sbx-Version kennt '--no-share-skills' NICHT"
      echo "    Die Sandbox würde den geteilten Skill-Store benutzen."
      ok=1
    fi
  fi

  return "$ok"
}

# Bewusst `printf` statt `cat <<EOF`: Ein Here-Doc legt die Zeilen erst in eine
# temporäre Datei. Rufst du solobox einmal aus einer eingeschränkten Umgebung
# heraus auf, ist das Temp-Verzeichnis nicht schreibbar — und dann scheitert
# schon die Hilfe.
usage() {
  printf '%s\n' \
    'solobox — eine einzige Claude-Sandbox für alle Projekte' \
    '' \
    'Aufruf: solobox <kommando> [argument]' \
    '' \
    '  up [pfad]     Sandbox anlegen (beim ersten Mal) und Claude starten —' \
    '                im aktuellen Verzeichnis, oder in [pfad].' \
    '' \
    '  build [--force]' \
    '                Image bauen und als sbx-Template registrieren.' \
    '' \
    '  check [--base]' \
    '                Prüfen, ob etwas neu gebaut oder neu angelegt werden muss —' \
    '                und die BILLIGSTE ausreichende Maßnahme nennen.' \
    '                Exitcode: 0 aktuell, 1 sync, 2 build, 3 rm+up.' \
    '                --base fragt zusätzlich die Registry, ob sich das' \
    '                Basis-Image bewegt hat (braucht Netz).' \
    '' \
    '  sync          Skills, Settings und MCP-Server in die LAUFENDE Sandbox' \
    '                nachziehen, ohne sie neu anzulegen.' \
    '' \
    '  shell [pfad]  Eine bash-Shell in der Sandbox öffnen.' \
    '' \
    '  allow <host>  Einen Host für die Sandbox freigeben.' \
    '' \
    '  status        Template, Sandbox, Wurzeln, MCP-Server, Nachbarn.' \
    '' \
    '  update        Template neu bauen und sagen, was das der bestehenden' \
    '                Sandbox NICHT bringt.' \
    '' \
    '  install       Symlink nach ~/.local/bin/solobox legen.' \
    '' \
    '  doctor        Prüfen, ob der Host alles bereithält.' \
    '' \
    '  rm            Die Sandbox entfernen (fragt vorher nach).' \
    '' \
    'Konfiguration (optional): ~/.config/solobox/solobox.conf' \
    'Vorlage: v2/solobox.conf.example'
}

# --- Einstiegspunkt ----------------------------------------------------------

case "${1:-}" in
  up)      shift; require_tools; load_config; cmd_up      "$@" ;;
  build)   shift; require_tools; load_config; cmd_build   "$@" ;;
  check)   shift; require_tools; load_config; cmd_check   "$@" ;;
  sync)    shift; require_tools; load_config; cmd_sync    "$@" ;;
  shell)   shift; require_tools; load_config; cmd_shell   "$@" ;;
  allow)   shift; require_tools; load_config; cmd_allow   "$@" ;;
  status)  shift; require_tools; load_config; cmd_status  "$@" ;;
  update)  shift; require_tools; load_config; cmd_update  "$@" ;;
  rm)      shift; require_tools; load_config; cmd_rm      "$@" ;;
  install) shift;                load_config; cmd_install "$@" ;;
  doctor)  shift;                load_config; cmd_doctor  "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unbekanntes Kommando '$1'. 'solobox help' zeigt die Übersicht." ;;
esac
