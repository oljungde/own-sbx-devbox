#!/usr/bin/env bash

# ⚠️  Läuft dieses Skript wirklich unter bash? `sh sbx-claude.sh` ignoriert die
#     Shebang-Zeile oben, und /bin/sh ist auf macOS eine Bash 3.2 im
#     POSIX-Modus. Die kennt keine Prozess-Substitution und bricht mitten im
#     Skript ab — mit einer Meldung, die nach einem Tippfehler weit hinten
#     aussieht statt nach einem falschen Startbefehl:
#
#       sbx-claude.sh: line 612: syntax error near unexpected token `<'
#
#     Zwei Fälle sind zu unterscheiden, und der zweite ist der gemeine:
#       1. eine andere Shell (zsh, dash) -> BASH_VERSION ist leer
#       2. bash IM POSIX-MODUS, weil als `sh` aufgerufen -> BASH_VERSION ist
#          gesetzt! Erkennbar nur an `shopt -qo posix`.
#
#     Statt zu meckern starten wir uns unter bash neu. Diese Prüfung steht ganz
#     vorne und ist in POSIX-Syntax gehalten: bash liest Skripte stückweise, sie
#     greift also, bevor die erste unverdauliche Zeile erreicht wird.
if [ -z "${BASH_VERSION:-}" ] || shopt -qo posix 2>/dev/null; then
  if command -v bash >/dev/null 2>&1; then
    echo "Hinweis: sbx-claude.sh braucht bash — ich starte mich neu." >&2
    exec bash "$0" "$@"
  fi
  echo "FEHLER: sbx-claude.sh braucht bash, und bash ist nicht installiert." >&2
  exit 1
fi

set -euo pipefail

# =============================================================================
# sbx-claude.sh — eine Sandbox pro Projekt, alle aus demselben Image
#
# Der Unterschied zu den beiden anderen Varianten in einem Satz: devbox fragt
# "welches Profil?", solobox fragt nichts und hat genau eine Box — sbx-claude
# fragt auch nichts, legt aber pro PROJEKT eine eigene Sandbox an. Die
# Sandbox-Grenze verläuft damit dort, wo die Projektgrenze verläuft.
#
# Zwei Dinge kann diese Variante, die die anderen nicht können:
#
#   1. Eine Benachrichtigung, die im Container wirklich funktioniert. Die
#      anderen Varianten SCHALTEN die Notification-Hooks des Hosts AB, weil sie
#      `osascript` aufrufen. Hier bringt das Image eigene, portable Hooks mit,
#      die über eine Datei im gemeinsamen Ordner mit dem Host reden.
#
#   2. Berechtigungen, die nur bei git fragen. `bypassPermissions` fragt
#      nirgends — ausser bei den Regeln in `ask` und `deny`, und die gelten laut
#      Dokumentation "in every mode, including bypassPermissions".
#
# Was diese Variante dafür AUFGIBT: Ein neues Image erreicht bestehende
# Sandboxes nicht. Bei zehn Projekten heisst Nachrüsten zehnmal löschen,
# anlegen, anmelden. Deshalb ist das Dockerfile voll ausgestattet, und deshalb
# ist die Drift-Prüfung hier wichtiger als in den anderen Varianten.
#
# Wie die anderen Wrapper benutzt dieses Skript bewusst nur stabile sbx-Flags.
# Die EINE Ausnahme ist `--no-share-skills` hinter ISOLATE_SKILLS — sie ist
# gekennzeichnet, standardmässig aus, und das Skript überlebt es, wenn das Flag
# eines Tages verschwindet.
#
# Aufruf:  sbx-claude <kommando> [argument]
# =============================================================================

# --- Feste Grössen -----------------------------------------------------------

IMAGE="sbx-claude/base:latest"

# Alle Sandboxes dieses Setups beginnen damit. Jede Listen- und
# Löschoperation filtert strikt darauf: auf derselben Maschine können fremde
# Sandboxes laufen, die uns nichts angehen.
PRAEFIX="sbx-claude-"

# Das Basis-Image aus der FROM-Zeile des Dockerfiles. Beim Bauen wird sein
# Digest als Label ins Image geschrieben — reine Herkunftsangabe, damit man
# später nachsehen kann, worauf ein Image aufsetzt. Ändert sich die FROM-Zeile,
# gehört diese hier mitgeändert.
BASE_IMAGE="docker/sandbox-templates:claude-code-docker"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sbx-claude"

# Der Rückkanal aus der Sandbox auf den Host. Wird read-write in JEDE
# Projekt-Sandbox eingehängt; der Hook im Container schreibt hier hinein, der
# Wächter auf dem Host liest.
EVENTS_DIR="$STATE_DIR/events"

# ⚠️  Symlinks auflösen, BEVOR aus dem Skriptpfad das Verzeichnis wird.
#     `sbx-claude` wird über einen Symlink in ~/.local/bin aufgerufen (siehe
#     `install`). Ohne Auflösung zeigt ${BASH_SOURCE[0]} genau dorthin, und das
#     Skript sucht sein Dockerfile in ~/.local/bin:
#
#       shasum: /Users/du/.local/bin/Dockerfile: No such file or directory
#
#     `readlink -f` gibt es auf macOS nicht verlässlich, deshalb die Schleife.
#     Sie folgt auch einer Kette und behandelt relative Ziele.
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
WATCH_SKRIPT="$SCRIPT_DIR/hooks/watch.sh"

# Sofort prüfen statt später mit einer shasum-Fehlermeldung zu scheitern.
if [ ! -f "$DOCKERFILE" ]; then
  printf 'FEHLER: Dockerfile nicht gefunden: %s\n' "$DOCKERFILE" >&2
  printf 'FEHLER: sbx-claude.sh erwartet es im selben Ordner. Repo verschoben?\n' >&2
  printf 'FEHLER: Dann den Symlink neu setzen: <repo>/v3/sbx-claude.sh install\n' >&2
  exit 1
fi

BIN_LINK="${SBX_CLAUDE_BIN:-$HOME/.local/bin/sbx-claude}"
CONFIG_FILE="${SBX_CLAUDE_CONFIG:-$HOME/.config/sbx-claude/sbx-claude.conf}"

# Der LaunchAgent des Wächters.
AGENT_LABEL="dev.sbx-claude.watch"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

# --- Standardwerte (von der Konfiguration überschreibbar) --------------------

# Zusätzliche Netz-Hosts, global für alle Projekte.
EXTRA_HOSTS=()

# Eigenständige MCP-Server, die auf dem HOST mit `sbx mcp add` registriert
# wurden. Server aus deinen Plugins gehören hier NICHT hinein — die laufen im
# Container und brauchen nur Netz-Freigaben.
MCP_SERVERS=()

# ⚠️  bypassPermissions ist hier bewusst der Standard, und das ist nur zusammen
#     mit GIT_ASK_VERBEN und den deny-Regeln vertretbar. Der Workspace ist ein
#     echter Bind-Mount: der Container schützt dein SYSTEM, nicht dein REPO.
#     Erlaubte Werte: bypassPermissions, acceptEdits, default, plan.
PERMISSION_MODE="bypassPermissions"

# Die schreibenden git-Verben. Für jedes entsteht eine ask-Regel, die auch im
# bypass-Modus eine Rückfrage erzwingt. Lesende Verben (status, log, diff, show,
# blame) fehlen absichtlich: sie fassen nichts an, und Claude braucht sie
# ständig zur Orientierung.
GIT_ASK_VERBEN=(
  add commit push pull fetch merge rebase reset checkout restore switch
  stash clean tag cherry-pick revert branch remote submodule worktree
  gc reflog filter-branch am apply rm mv init clone config update-ref
  prune notes bisect send-email replace
)

# Das Irreversible ausserhalb von git. Ohne diese Liste wäre git die einzige
# Ausnahme von bypass — `rm -rf` im Nachbarordner liefe ohne Rückfrage durch.
#
# `Bash(sh)` ist kein Tippfehler: bei `curl … | sh` trennt Claude Code an der
# Pipe, `sh` ist dann ein eigenes Segment — und genau das wollen wir sehen.
#
# ⚠️  Die drei `-c`-Muster sind der Ersatz für einen eigenen Hook, den diese
#     Fassung hatte und wieder losgeworden ist. Nachgemessen: Regeln werden auf
#     JEDES Segment einer Kette angewendet und auch in Command-Substitution —
#     `cd repo && git push` und `x=$(git push)` lösen die git-Regeln also von
#     selbst aus. Was Muster wirklich nicht sehen, ist ein Kommando in einer
#     Zeichenkette: `bash -c "git push"`. Statt dafür git-Verben in der ganzen
#     Zeile zu suchen, fragen wir beim Verpacken selbst nach — das ist die
#     ehrlichere Regel und drei Zeilen statt 133.
EXTRA_ASK=(
  "Bash(rm -rf *)" "Bash(rm -fr *)" "Bash(sudo *)"
  "Bash(chmod -R *)" "Bash(chown -R *)" "Bash(dd *)"
  "Bash(sh)" "Bash(shutdown *)" "Bash(reboot *)"
  "Bash(bash -c *)" "Bash(sh -c *)" "Bash(zsh -c *)"
)

# Ab wie vielen Sekunden Antwortdauer eine "fertig"-Meldung kommt. Stop feuert
# nach JEDER Antwort; ungefiltert wären das bei einem langen Dialog dutzende
# Meldungen — und dann schaltet man sie ab.
NOTIFY_SCHWELLE=60

# Welche Hook-Ereignisse aus deiner globalen settings.json übernommen werden.
# Absichtlich eine Liste und keine Heuristik. Notification, Stop und
# UserPromptSubmit fehlen hier, weil sbx-claude sie SELBST besetzt — mit dem
# portablen Hook aus dem Image. Die Hooks des Hosts rufen
# `terminal-notifier`/`osascript` und würden hier scheitern.
HOOK_UEBERNEHMEN=(PreToolUse PostToolUse SubagentStop PreCompact SessionEnd)

# 0 = Skills kommen aus sbx' geteiltem Store (`sbx skills import`).
# 1 = diese Sandbox hängt den Store nicht ein (`--no-share-skills`).
#     Für Projekte, deren Code du nicht kennst: der Store ist read-write und
#     maschinenweit geteilt, ein Agent könnte dort einen Skill verändern, den
#     morgen ein anderes Projekt ausführt.
ISOLATE_SKILLS=0

# Was aus ~/.claude read-only eingehängt wird. `skills` fehlt: die übernimmt
# `sbx skills import`.
CLAUDE_SHARED=(agents commands rules plugins output-styles workflows)

# Was davon zusätzlich nach /home/agent/.claude verlinkt wird. sbx hängt am
# HOST-Pfad ein, im Container ist $HOME aber /home/agent — ohne diese Brücke
# findet Claude nichts.
CLAUDE_LINKED=(agents commands rules plugins output-styles workflows)

# Die Netz-Grundausstattung. Deny-by-default heisst: was hier fehlt, geht nicht.
BASE_HOSTS=(
  'api.anthropic.com'                      # Claude selbst
  '*.anthropic.com'
  '*.claude.ai'                            # Login und Connectors
  'github.com'                             # git, gh
  '*.github.com'
  '*.githubusercontent.com'
  'cli.github.com'
  '*.npmjs.org'                            # npm, pnpm
  '*.nodejs.org'
  'pypi.org'                               # pip, uv, poetry
  'files.pythonhosted.org'
  '*.astral.sh'                            # uv und Python-Interpreter
  '*.aikido.dev'                           # Safe-Chain-Prüfungen
  '*.playwright.dev'                       # Playwright
  'playwright.download.prss.microsoft.com'
  '*.microsoft.com'
  '*.context7.com'                         # Context7-MCP
  '*.atlassian.com'                        # Atlassian-Plugin
  '*.atlassian.net'
  '*.figma.com'                            # Figma-Plugin
  '*.docker.io'
  'ghcr.io'
  'localhost'
)

# --- Kleine Helfer -----------------------------------------------------------

info() { printf '>> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

require_tools() {
  command -v sbx    >/dev/null 2>&1 || die "'sbx' nicht gefunden. Docker Sandboxes installieren."
  command -v docker >/dev/null 2>&1 || die "'docker' nicht gefunden. Docker Desktop installieren."
}

# --- Projekt bestimmen -------------------------------------------------------

# Die Git-Wurzel, nicht das aktuelle Verzeichnis. Sonst bekämen `projekt/`,
# `projekt/src/` und `projekt/test/` je eine eigene Sandbox — drei Boxen und
# drei Anmeldungen für ein Repo.
projekt_wurzel() {
  local start="${1:-$PWD}" wurzel
  start="$(cd "$start" 2>/dev/null && pwd -P)" || die "Verzeichnis nicht lesbar: ${1:-$PWD}"
  if wurzel="$(cd "$start" && git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$wurzel"
    return 0
  fi
  # Kein Git-Repo: das Verzeichnis selbst, aber sichtbar gemeldet — sonst wundert
  # man sich später über eine Sandbox pro Unterordner.
  warn "'$start' ist kein Git-Repo — ich nehme den Ordner selbst als Projekt."
  printf '%s\n' "$start"
}

# Aus dem Pfad einen sbx-taugliches Namen machen. sbx erlaubt nur Buchstaben,
# Ziffern, Bindestrich, Punkt und Plus — KEINEN Unterstrich.
name_bereinigen() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9.+-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

pfad_notiz() { printf '%s\n' "$STATE_DIR/$1.pfad"; }

# Name = Präfix + bereinigter Basename der Projektwurzel. Zwei Projekte können
# gleich heissen (~/dev/own/api und ~/dev/work/api), deshalb die Kollisionsprobe
# gegen die notierte Zuordnung: gehört der Name schon einem ANDEREN Pfad, kommt
# ein kurzer Hash aus dem vollen Pfad dazu.
sandbox_name() {
  local projekt="$1" basis kurz notiz gemerkt
  basis="$(name_bereinigen "$(basename "$projekt")")"
  [ -n "$basis" ] || basis="projekt"
  kurz="$PRAEFIX$basis"

  notiz="$(pfad_notiz "$kurz")"
  if [ -f "$notiz" ]; then
    gemerkt="$(cat "$notiz" 2>/dev/null || true)"
    if [ -n "$gemerkt" ] && [ "$gemerkt" != "$projekt" ]; then
      printf '%s+%s\n' "$kurz" "$(printf '%s' "$projekt" | shasum -a 256 | cut -c1-6)"
      return 0
    fi
  fi
  printf '%s\n' "$kurz"
}

# --- Sandbox-Zustand ---------------------------------------------------------

# `|| true` ist hier Pflicht, nicht Vorsicht: `sbx ls` endet mit Exitcode 1,
# wenn man nicht bei Docker angemeldet ist. Mit `set -e` bräche das Skript sonst
# stumm ab.
sandboxes() { sbx ls -q 2>/dev/null | grep "^$PRAEFIX" || true; }

sandbox_exists() {
  if sbx ls -q 2>/dev/null | grep -qx "$1"; then
    return 0
  fi
  return 1
}

sandbox_running() {
  sbx ls 2>/dev/null | awk -v n="$1" '$1 == n && $3 == "running" { gefunden = 1 } END { exit !gefunden }'
}
sandbox_stamp() { sbx exec "$1" cat /etc/sbx-claude-stamp 2>/dev/null | tr -d '\r\n' || true; }

# Der Stempel, den die Sandbox beim Anlegen bekam — als Notiz auf dem HOST.
notiz_stempel() { printf '%s\n' "$STATE_DIR/$1.stempel"; }

# Auf welchem Image läuft diese Sandbox? Gibt zwei Wörter zurück:
#   <aktuell|veraltet|ohne-stempel|unbekannt> <beobachtet|notiert|keine-notiz>
#
# ⚠️  Warum es zwei Quellen gibt, und warum das nicht doppelt gemoppelt ist:
#
#     Die gute Quelle ist /etc/sbx-claude-stamp IN der Box — eine beobachtete
#     Tatsache, die nicht lügen kann. Sie ist aber nur lesbar, wenn die Box
#     LÄUFT: `sbx exec` würde eine gestoppte Box sonst erst starten, und dann
#     bootet ein blosses `status` acht Container.
#
#     Bei einer Box pro Projekt sind die meisten gestoppt. Ohne zweite Quelle
#     wäre die Antwort im Normalfall also "weiss nicht" — und `up` liefe mit
#     einem alten Image weiter, ohne es zu sagen. Deshalb notiert `provision`
#     den Dockerfile-Hash beim Anlegen auf dem Host.
#
#     Die Notiz ist die schwächere Quelle: sie kann fehlen oder von Hand
#     verstellt sein. Deshalb gewinnt immer die Beobachtung, wenn es sie gibt,
#     und die Ausgabe sagt dazu, woher die Auskunft kommt.
sandbox_stand() {
  local sandbox="$1" hier dort
  hier="$(current_hash)"

  if sandbox_running "$sandbox"; then
    dort="$(sandbox_stamp "$sandbox")"
    if [ -z "$dort" ]; then
      printf 'ohne-stempel beobachtet\n'
    elif [ "$dort" = "$hier" ]; then
      printf 'aktuell beobachtet\n'
    else
      printf 'veraltet beobachtet\n'
    fi
    return 0
  fi

  dort="$(cat "$(notiz_stempel "$sandbox")" 2>/dev/null || true)"
  if [ -z "$dort" ]; then
    printf 'unbekannt keine-notiz\n'
  elif [ "$dort" = "$hier" ]; then
    printf 'aktuell notiert\n'
  else
    printf 'veraltet notiert\n'
  fi
}

# Die tatsächlich eingehängten Workspaces — ohne jq, weil der Host keins haben
# muss.
aktuelle_mounts() {
  sbx ls --json 2>/dev/null | awk -v n="\"$1\"" '
    $1 == "\"name\":" && $2 == n","      { treffer = 1 }
    treffer && $1 == "\"workspaces\":"   { drin = 1; next }
    drin && /\]/                         { exit }
    drin {
      gsub(/[",]/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "") print
    }
  ' || true
}

sbx_erreichbar()   { sbx ls -q >/dev/null 2>&1; }
docker_erreichbar() { docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }

# --- Image-Zustand -----------------------------------------------------------

hash_file()     { printf '%s\n' "$STATE_DIR/image.hash"; }
recorded_hash() { cat "$(hash_file)" 2>/dev/null || true; }
current_hash()  { shasum -a 256 "$DOCKERFILE" | cut -d' ' -f1; }

template_id() {
  sbx template ls 2>/dev/null | awk '
    $1 == "docker.io/sbx-claude/base" && $2 == "latest" { print $3; exit }
    $1 == "sbx-claude/base"           && $2 == "latest" { print $3; exit }
  ' || true
}

image_stamp() {
  docker image inspect "$IMAGE" \
    --format '{{index .Config.Labels "sbx-claude.dockerfile-sha"}}' 2>/dev/null || true
}
local_image_id() {
  docker images --format '{{.ID}}' "$IMAGE" 2>/dev/null | head -n1 || true
}
basis_digest() {
  docker buildx imagetools inspect "$BASE_IMAGE" \
    --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

supports_no_share_skills() {
  # `--no-share-skills` steht NICHT in `sbx create --help` und gehört zum
  # EXPERIMENTAL-Kommando `sbx skills`. Ohne diese Probe dürfte es nirgends
  # verwendet werden.
  #
  # ⚠️  Explizites if und kein `cmd && return 1`. Eine &&-Kette, deren erster
  #     Teil fehlschlägt, ist ein nicht-null Exitcode — und unter `set -e` reisst
  #     das das Skript ab, sobald die Funktion einmal NICHT in einer Bedingung
  #     steht. Das ist eine Falle, die man erst Monate später tritt.
  if sbx create claude --no-share-skills --help 2>&1 | grep -qi 'unknown flag'; then
    return 1
  fi
  return 0
}

share_skills_aktiv() {
  if sbx settings get feature.shareSkills --json 2>/dev/null \
       | tr -d ' \n' | grep -q '"value":{"enabled":true'; then
    return 0
  fi
  return 1
}

# --- Bauen -------------------------------------------------------------------

cmd_build() {
  local now recorded basis tarball
  now="$(current_hash)"
  recorded="$(recorded_hash)"

  # Der zweite Test ist der wichtige: die Merkdatei kann stimmen, während das
  # Template im sbx-Store fehlt (anderer Rechner, `sbx reset`, Handarbeit).
  if [ "$now" = "$recorded" ] && [ -n "$(template_id)" ] && [ "${1:-}" != "--force" ]; then
    info "Dockerfile unverändert und Template vorhanden — nichts zu tun."
    info "Trotzdem bauen: sbx-claude build --force"
    return 0
  fi

  docker_erreichbar || die "Der Docker-Daemon antwortet nicht. Docker Desktop gestartet?"

  basis="$(basis_digest)"
  [ -n "$basis" ] || basis="unbekannt"

  info "baue $IMAGE (Chromium ist dabei, das dauert) ..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" \
    --build-arg SBX_CLAUDE_STAMP="$now" \
    --build-arg SBX_CLAUDE_BASE_DIGEST="$basis" \
    "$SCRIPT_DIR"

  # ⚠️  Der Umweg, der alle überrascht: Der sbx-Runtime hat einen EIGENEN
  #     Image-Store, getrennt von Docker Desktop. Ein lokal gebautes Image
  #     kennt er nicht — es muss als Tarball hinüber. Und zwar bei JEDEM Bau
  #     komplett, deshalb dauert dieser Schritt.
  tarball="$(mktemp -t sbx-claude-image)"
  info "exportiere das Image (mehrere GB) ..."
  docker save "$IMAGE" -o "$tarball"
  info "Grösse: $(du -h "$tarball" | cut -f1)"

  info "lade das Image in den sbx-Template-Store ..."
  sbx template load "$tarball"
  rm -f "$tarball"

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$now" > "$(hash_file)"
  info "fertig."
}

# --- Mounts: die einzige Quelle ----------------------------------------------

# ⚠️  Diese Funktion ist die EINZIGE Liste der Workspaces. `provision` legt
#     danach an, `pruefe_stand` vergleicht dagegen. Wer eine zweite Liste
#     einführt, bricht den Drift-Check — dann meldet er ewig Unterschiede oder
#     übersieht echte.
gewuenschte_mounts() {
  local projekt="$1" d
  printf '%s\n' "$projekt"
  for d in "${CLAUDE_SHARED[@]}"; do
    mkdir -p "$HOME/.claude/$d"
    # Die Klammern um $d sind kein Zierrat: in zsh würde "$HOME/.claude/$d:ro"
    # als History-Modifier ":r" gelesen und ergäbe "…/agentso".
    printf '%s\n' "$HOME/.claude/${d}:ro"
  done
  mkdir -p "$EVENTS_DIR"
  printf '%s\n' "$EVENTS_DIR"
}

provision() {
  local projekt="$1" sandbox="$2"
  local mounts=() flags=() eintrag antwort

  [ -d "$projekt" ] || die "'$projekt' ist kein Verzeichnis. sbx hängt nur VERZEICHNISSE ein."

  # Prozess-Substitution, keine Pipe: Eine Pipe steckte die Schleife in eine
  # Subshell, und das gefüllte Array wäre danach wieder leer.
  while IFS= read -r eintrag; do
    mounts+=("$eintrag")
  done < <(gewuenschte_mounts "$projekt")

  if [ "$ISOLATE_SKILLS" = "1" ]; then
    if supports_no_share_skills; then
      info "ISOLATE_SKILLS=1 — diese Sandbox hängt den geteilten Skill-Store nicht ein."
      flags+=(--no-share-skills)
    else
      warn "ISOLATE_SKILLS=1 gewünscht, aber diese sbx-Version kennt"
      warn "--no-share-skills nicht. Die Sandbox würde den Store einhängen."
      read -r -p "Trotzdem anlegen? [j/N] " antwort
      case "$antwort" in j|J|ja|Ja) ;; *) die "abgebrochen." ;; esac
    fi
  fi

  info "lege Sandbox '$sandbox' an ..."
  sbx create ${flags[@]+"${flags[@]}"} -t "$IMAGE" --name "$sandbox" claude "${mounts[@]}"

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$projekt" > "$(pfad_notiz "$sandbox")"
  # Der Dockerfile-Hash zum Zeitpunkt des Anlegens. Damit ist auch bei einer
  # GESTOPPTEN Box beantwortbar, ob sie auf dem aktuellen Image läuft — siehe
  # sandbox_stand(). Vorher stand hier die Template-ID, die nie wieder gelesen
  # wurde: ein Merkzettel ohne Leser ist kein Zustand, sondern Ballast.
  printf '%s\n' "$(current_hash)" > "$(notiz_stempel "$sandbox")"
}

# --- Netz --------------------------------------------------------------------

# Die projektlokale Liste liegt dort, wo der Agent schreiben darf. Er könnte
# sich selbst Hosts freigeben — und die Netzfreigabe ist die eine Grenze, die
# gegen Exfiltration wirkt. Deshalb wird sie gezeigt und einmal bestätigt.
projekt_hosts() {
  local datei="$1/.sbx-claude-hosts"
  [ -f "$datei" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$datei" 2>/dev/null | tr -d ' \t' || true
}

apply_network() {
  local projekt="$1" sandbox="$2"
  local hosts=() host neu=() merk gemerkt antwort

  hosts=("${BASE_HOSTS[@]}")
  # Explizites if statt einer &&-Kette: unter `set -e` ist eine Kette, deren
  # Test fehlschlägt, ein nicht-null Exitcode — an der falschen Stelle bricht
  # damit das ganze Skript ab.
  if [ "${#EXTRA_HOSTS[@]}" -gt 0 ]; then
    hosts+=("${EXTRA_HOSTS[@]}")
  fi

  merk="$STATE_DIR/$sandbox.hosts-bestaetigt"
  gemerkt="$(cat "$merk" 2>/dev/null || true)"

  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if printf '%s\n' "$gemerkt" | grep -qxF "$host"; then
      hosts+=("$host")
    else
      neu+=("$host")
    fi
  done < <(projekt_hosts "$projekt")

  if [ "${#neu[@]}" -gt 0 ]; then
    warn "Das Projekt möchte zusätzliche Netz-Freigaben (.sbx-claude-hosts):"
    for host in "${neu[@]}"; do warn "    $host"; done
    warn "Diese Datei liegt im Repo — der Agent kann sie ändern."
    read -r -p "Freigeben? [j/N] " antwort
    case "$antwort" in
      j|J|ja|Ja)
        mkdir -p "$STATE_DIR"
        for host in "${neu[@]}"; do
          hosts+=("$host")
          printf '%s\n' "$host" >> "$merk"
        done
        ;;
      *) info "übersprungen — die Sandbox läuft ohne diese Hosts." ;;
    esac
  fi

  info "setze Netzregeln für '$sandbox' ..."
  # ⚠️  Ausschliesslich --sandbox-scoped. Eine globale Regel würde die Policy
  #     eines fremden sbx-Setups auf derselben Maschine mitverändern.
  #     "Already covered in policy" ist ab dem zweiten Start der Normalfall und
  #     kein Fehler — deshalb filtern wir es aus der Ausgabe.
  for host in "${hosts[@]}"; do
    sbx policy allow network --sandbox "$sandbox" "$host" 2>&1 \
      | grep -vF 'Already covered in policy' || true
  done
}

# --- Globale Konfiguration verbrücken ---------------------------------------

link_shared_config() {
  local sandbox="$1" dirs="${CLAUDE_LINKED[*]}"
  info "verlinke Agents, Commands, Rules, Plugins ..."
  sbx exec "$sandbox" bash -c "
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
  " || warn "Verlinken fehlgeschlagen — die Sandbox läuft trotzdem."
}

# --- Skills über sbx' eigenen Store -----------------------------------------

import_skills() {
  # ⚠️  Das ist der native Weg, und er hat einen Preis, der nicht in v3 steckt:
  #     `feature.shareSkills` ist eine MASCHINENWEITE sbx-Einstellung. Ist sie
  #     an, hängt JEDE Sandbox auf diesem Rechner den geteilten Store ein — auch
  #     fremde und auch eine solobox, deren eigener Skill-Kopierschritt dann in
  #     den Store schreibt statt in einen Sandbox-Ordner. Der Store ist
  #     read-write und von allen geteilt.
  #
  #     Deshalb schalten wir das Flag NICHT still um.
  if ! share_skills_aktiv; then
    warn "sbx' geteilter Skill-Store ist nicht aktiv (feature.shareSkills = false)."
    warn "Ohne ihn hängt keine Sandbox den Store ein — 'sbx skills import' wäre wirkungslos."
    warn "Einschalten wirkt MASCHINENWEIT, also auch auf fremde Sandboxes."
    read -r -p "feature.shareSkills jetzt einschalten? [j/N] " antwort
    case "$antwort" in
      j|J|ja|Ja)
        sbx settings set feature.shareSkills true \
          || { warn "Einschalten fehlgeschlagen — Skills bleiben aussen vor."; return 0; }
        warn "Eingeschaltet. Bestehende Sandboxes bekommen den Store erst beim Neuanlegen."
        ;;
      *)
        info "übersprungen — die Sandbox startet ohne globale Skills."
        return 0
        ;;
    esac
  fi

  info "importiere globale Skills in sbx' Store ..."
  sbx skills import --force || warn "Skill-Import fehlgeschlagen — die Sandbox läuft trotzdem."
}

# --- settings.json ableiten --------------------------------------------------

# Eine Liste von Strings als JSON-Array-Inhalt. Bewusst in bash und nicht mit
# python: das python3 auf dem Host ist auf manchen Rechnern ein Wrapper und
# nicht verlässlich aufrufbar. Die Werte hier sind alle unsere eigenen
# Konstanten ohne Anführungszeichen oder Backslashes, es gibt also nichts zu
# maskieren.
json_liste() {
  local erste=1 wert
  for wert in "$@"; do
    [ "$erste" = 1 ] && erste=0 || printf ', '
    printf '"%s"' "$wert"
  done
}

# Die Vorgabe-Datei: alles, was NICHT vom Host kommt, sondern von sbx-claude
# gesetzt wird. Sie wird in die Sandbox kopiert und dort über die vom Host
# übernommenen Werte gelegt.
#
# Die Hook-Kommandos bekommen den Ereignisordner, den Sandbox-Namen und die
# Schwelle als ARGUMENTE mitgegeben. Beides könnte nicht im Image stehen — der
# Ordner ist ein Host-Pfad, der Name entsteht erst pro Projekt — und eine eigene
# Umgebungsdatei in der Sandbox war ein Umweg mit einem zusätzlichen Fehlerfall.
# Hier ist die Stelle, an der beide Werte ohnehin bekannt sind.
#
# Der Pfad steht in einfachen Anführungszeichen: er landet in einer Shell-Zeile,
# und ohne Klammerung bräche ein Leerzeichen im Pfad den Aufruf.
vorgabe_schreiben() {
  local ziel="$1" sandbox="$2" verb ask=() notify

  for verb in "${GIT_ASK_VERBEN[@]}"; do
    # ⚠️  Bewusst `git *VERB*` und nicht `git VERB *`. Sonst rutscht jede
    #     globale Option davor durch, ohne dass gefragt wird:
    #       git -C unterordner commit -m "..."
    #     Der Preis ist ein gelegentlicher Fehlalarm (`git log --grep=push`
    #     fragt auch) — der kostet einen Klick, ein übersehener Push kostet mehr.
    ask+=("Bash(git *${verb}*)")
  done
  if [ "${#EXTRA_ASK[@]}" -gt 0 ]; then
    ask+=("${EXTRA_ASK[@]}")
  fi

  notify="/usr/local/bin/sbx-claude-notify"

  mkdir -p "$(dirname "$ziel")"
  {
    printf '{\n'
    printf '  "permissions": {\n'
    printf '    "defaultMode": "%s",\n' "$PERMISSION_MODE"
    printf '    "ask": [%s],\n' "$(json_liste "${ask[@]}")"
    # `bypassPermissions` schaltet laut Dokumentation ausgerechnet den Schutz
    # der "protected paths" wie .git ab. Ohne diese Regeln könnte Claude mit dem
    # Werkzeug Write an der Historie vorbei direkt in .git/ schreiben.
    printf '    "deny": [%s]\n' "$(json_liste \
      'Edit(.git/**)' 'Write(.git/**)' 'Edit(**/.git/**)' 'Write(**/.git/**)')"
    printf '  },\n'
    printf '  "hooks": {\n'
    printf '    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "%s start '\''%s'\'' %s %s", "timeout": 5}]}],\n' \
      "$notify" "$EVENTS_DIR" "$sandbox" "$NOTIFY_SCHWELLE"
    printf '    "Stop": [{"hooks": [{"type": "command", "command": "%s stop '\''%s'\'' %s %s", "timeout": 5}]}],\n' \
      "$notify" "$EVENTS_DIR" "$sandbox" "$NOTIFY_SCHWELLE"
    printf '    "Notification": [{"hooks": [{"type": "command", "command": "%s wartet '\''%s'\'' %s %s", "timeout": 5}]}]\n' \
      "$notify" "$EVENTS_DIR" "$sandbox" "$NOTIFY_SCHWELLE"
    printf '  }\n'
    printf '}\n'
  } > "$ziel"
}

# Läuft IM Container. Der Host braucht dadurch kein python3 und kein jq.
SETTINGS_PY='
import json, pathlib, sys

modus     = sys.argv[1]
uebernehmen = set(sys.argv[2:])

def lade(p):
    p = pathlib.Path(p)
    try:
        return json.loads(p.read_text())
    except Exception:
        return {}

host    = lade("/tmp/sbx-claude-host.json")
vorgabe = lade("/tmp/sbx-claude-vorgabe.json")

ziel = pathlib.Path.home() / ".claude" / "settings.json"
cfg  = lade(ziel)

# 1:1 uebernommen — Einstellungen, die nichts ueber den Host verraten.
for key in ("enabledPlugins", "extraKnownMarketplaces", "model", "effortLevel"):
    if key in host:
        cfg[key] = host[key]

# Hooks: unsere eigenen gewinnen. Vom Host kommen nur die Ereignisse aus
# HOOK_UEBERNEHMEN — die uebrigen rufen terminal-notifier/osascript und
# wuerden hier scheitern.
hooks = {}
for ereignis, wert in host.get("hooks", {}).items():
    if ereignis in uebernehmen:
        hooks[ereignis] = wert
uebersprungen = sorted(set(host.get("hooks", {})) - uebernehmen)
hooks.update(vorgabe.get("hooks", {}))
cfg["hooks"] = hooks

# Der sandbox-Block des Hosts wird NICHT uebernommen: seine Pfade zeigen im
# Container ins Leere und sehen dabei aus, als schuetzten sie etwas.
cfg.pop("sandbox", None)

cfg["permissions"] = vorgabe.get("permissions", {})

# Das Basis-Image bringt eigene Werte mit. Ohne dieses Aufraeumen sagt die
# Datei zwei Dinge gleichzeitig.
if modus == "bypassPermissions":
    cfg["defaultMode"] = modus
    cfg["bypassPermissionsModeAccepted"] = True
else:
    cfg.pop("defaultMode", None)
    cfg.pop("bypassPermissionsModeAccepted", None)

ziel.parent.mkdir(parents=True, exist_ok=True)
ziel.write_text(json.dumps(cfg, indent=2) + "\n")

print("Berechtigungsmodus: " + modus)
print("Hooks aktiv: " + ", ".join(sorted(hooks)))
if uebersprungen:
    print("Hooks vom Host uebersprungen: " + ", ".join(uebersprungen))
print("git-Rueckfragen: " + str(len(cfg["permissions"].get("ask", []))) + " Regeln")
print("Plugins aktiviert: " + str(len(cfg.get("enabledPlugins", {}))))
'

apply_settings() {
  local sandbox="$1" quelle="$HOME/.claude/settings.json" vorgabe="$STATE_DIR/vorgabe.json"

  case "$PERMISSION_MODE" in
    bypassPermissions | acceptEdits | default | plan) ;;
    *) die "PERMISSION_MODE='$PERMISSION_MODE' ist unbekannt." ;;
  esac

  vorgabe_schreiben "$vorgabe" "$sandbox"

  info "leite settings.json für die Sandbox ab ..."
  if [ -f "$quelle" ]; then
    sbx cp "$quelle" "$sandbox:/tmp/sbx-claude-host.json" \
      || warn "Host-settings.json liess sich nicht kopieren — nur Vorgaben gelten."
  else
    info "keine globale settings.json gefunden — nur die Vorgaben gelten."
  fi
  sbx cp "$vorgabe" "$sandbox:/tmp/sbx-claude-vorgabe.json" \
    || { warn "Vorgabe liess sich nicht kopieren — settings.json unverändert."; return 0; }

  sbx exec "$sandbox" python3 -c "$SETTINGS_PY" "$PERMISSION_MODE" \
      ${HOOK_UEBERNEHMEN[@]+"${HOOK_UEBERNEHMEN[@]}"} \
    || warn "settings.json konnte nicht abgeleitet werden — die Sandbox läuft trotzdem."
}

# --- Git-Identität -----------------------------------------------------------

apply_git_identity() {
  local sandbox="$1" name email
  name="$(git config --global user.name  2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"

  if [ -z "$name" ] && [ -z "$email" ]; then
    warn "Keine globale Git-Identität auf dem Host — Commits hätten keinen Autor."
    return 0
  fi

  # Nur diese zwei Werte, nicht die ganze ~/.gitconfig: sbx kann keine einzelne
  # DATEI einhängen ("workspace path exists but is not a directory").
  info "übernehme Git-Identität ..."
  sbx exec "$sandbox" bash -c '
    [ -n "$1" ] && git config --global user.name  "$1"
    [ -n "$2" ] && git config --global user.email "$2"
    exit 0
  ' _ "$name" "$email" || warn "Git-Identität liess sich nicht setzen."
}

# --- MCP ---------------------------------------------------------------------

load_mcp() {
  local sandbox="$1" server
  [ "${#MCP_SERVERS[@]}" -gt 0 ] || return 0
  info "lade MCP-Server ..."
  for server in "${MCP_SERVERS[@]}"; do
    sbx mcp load "$server" --sandbox "$sandbox" \
      || warn "MCP-Server '$server' liess sich nicht laden. Registriert? 'sbx mcp ls'"
  done
}

# --- Alles anwenden ---------------------------------------------------------

alles_anwenden() {
  local projekt="$1" sandbox="$2"
  apply_network "$projekt" "$sandbox"
  link_shared_config "$sandbox"
  import_skills
  apply_settings "$sandbox"
  apply_git_identity "$sandbox"
  load_mcp "$sandbox"
}

# --- up ----------------------------------------------------------------------

cmd_up() {
  local projekt sandbox antwort frisch=0
  projekt="$(projekt_wurzel "${1:-$PWD}")"
  sandbox="$(sandbox_name "$projekt")"

  info "Projekt: $projekt"
  info "Sandbox: $sandbox"

  if [ -z "$(template_id)" ]; then
    info "kein Template im sbx-Store — ich baue zuerst."
    cmd_build
  fi

  # ⚠️  Die Reihenfolge ist wichtig und nicht beliebig: erst das IMAGE in Ordnung
  #     bringen, dann die SANDBOX dagegen prüfen. Umgekehrt würde man die Box
  #     neu anlegen und sie hinge sofort wieder am alten Image — zwei
  #     Neuanlagen samt zwei Anmeldungen für einen Vorgang.
  if sandbox_exists "$sandbox"; then
    STUFE=0
    pruefe_stand "$sandbox" "$projekt" >/dev/null || true

    if [ "$STUFE" -eq 2 ]; then
      warn "Das Image ist älter als das Dockerfile:"
      pruefe_stand "$sandbox" "$projekt" "    " || true
      warn "Neu bauen dauert Minuten (Chromium), erreicht diese Sandbox aber nicht"
      warn "von selbst — danach ist zusätzlich 'rm' und 'up' nötig."
      read -r -p "Image jetzt neu bauen? [j/N] " antwort
      case "$antwort" in
        j|J|ja|Ja)
          cmd_build --force
          STUFE=0
          pruefe_stand "$sandbox" "$projekt" >/dev/null || true
          ;;
        *) info "übersprungen — 'sbx-claude update' baut später neu." ;;
      esac
    fi

    if [ "$STUFE" -ge 3 ]; then
      warn "Diese Sandbox passt nicht mehr zum Image oder zur Konfiguration:"
      pruefe_stand "$sandbox" "$projekt" "    " || true
      warn "Workspaces sind nur beim Anlegen setzbar — Neuanlegen kostet die Anmeldung."
      read -r -p "Sandbox jetzt entfernen und neu anlegen? [j/N] " antwort
      case "$antwort" in
        j|J|ja|Ja)
          sbx rm --force "$sandbox" || die "Entfernen fehlgeschlagen."
          rm -f "$(notiz_stempel "$sandbox")"
          ;;
        *) info "unverändert weiter — die Meldungen oben bleiben gültig." ;;
      esac
    fi
  fi

  if ! sandbox_exists "$sandbox"; then
    provision "$projekt" "$sandbox"
    frisch=1
  fi

  alles_anwenden "$projekt" "$sandbox"

  if [ "$frisch" = "1" ]; then
    info "Erster Start dieses Projekts — melde dich einmal mit /login an."
    # ⚠️  Bewusst `sbx exec` und NICHT `sbx run`. `sbx run` startet den Agenten
    #     mit --dangerously-skip-permissions (in solobox mit `ps` in der Sandbox
    #     nachgemessen). Bei einer Box pro Projekt wäre das nicht die Ausnahme,
    #     sondern bei JEDEM neuen Projekt der Fall — der ganze
    #     Berechtigungsmodus wäre wirkungslos. `/login` funktioniert in `exec`
    #     genauso: Claude gibt eine URL aus, du öffnest sie auf dem Mac und
    #     klebst den Code zurück.
  fi

  info "starte Claude in '$projekt' ..."
  sbx exec -it -w "$projekt" "$sandbox" claude
}

cmd_sync() {
  local projekt sandbox
  projekt="$(projekt_wurzel "${1:-$PWD}")"
  sandbox="$(sandbox_name "$projekt")"
  sandbox_exists "$sandbox" || die "Keine Sandbox '$sandbox'. Zuerst 'sbx-claude up'."
  alles_anwenden "$projekt" "$sandbox"
  info "fertig. Eine laufende Sitzung muss für neue Settings neu gestartet werden."
}

# --- Drift-Prüfung -----------------------------------------------------------

STUFE=0
PRAEFIX_AUSGABE=""

# ⚠️  Warum die Einrückung ein PARAMETER ist und keine Pipe:
#     `pruefe_stand … | sed 's/^/  /'` sieht harmlos aus, steckt die Funktion
#     aber in eine Subshell — und dann ist $STUFE beim Aufrufer wieder 0 und der
#     Exitcode immer 0.
zeile() { printf '%s%s\n' "$PRAEFIX_AUSGABE" "$*"; }
melde() {
  local stufe="$1" zeichen="$2" text="$3"
  [ "$stufe" -gt "$STUFE" ] && STUFE="$stufe" || true
  printf '%s  %s %s\n' "$PRAEFIX_AUSGABE" "$zeichen" "$text"
}

# pruefe_stand <sandbox> <projekt> [einrueckung]
#
# Geprüft wird nur, was zu DIESER Sandbox gehört. Der Wächter zum Beispiel ist
# Host-Zustand und stand hier einmal drin — das hat die Stufen durcheinander
# gebracht ("Stufe 1, also sync" stimmte dann nicht mehr). Er gehört in `doctor`.
pruefe_stand() {
  local sandbox="$1" projekt="$2"
  PRAEFIX_AUSGABE="${3:-}"
  local soll ist hier dort stempel fehlend ueberzaehlig eintrag

  zeile "--- 1. Image gegen Dockerfile ---"
  hier="$(current_hash)"
  if ! docker_erreichbar; then
    melde 0 "·" "Docker antwortet nicht — übersprungen"
  elif [ -z "$(local_image_id)" ]; then
    melde 2 "✗" "Image '$IMAGE' fehlt — 'sbx-claude build'"
  else
    stempel="$(image_stamp)"
    if [ -z "$stempel" ]; then
      melde 2 "✗" "Image trägt keinen Stempel — mit einer alten Fassung gebaut, 'sbx-claude update'"
    elif [ "$stempel" = "$hier" ]; then
      melde 0 "✓" "Image passt zum Dockerfile"
    else
      melde 2 "✗" "Dockerfile hat sich geändert — 'sbx-claude update'"
    fi
  fi

  zeile "--- 2. Template im sbx-Store ---"
  if ! sbx_erreichbar; then
    melde 0 "·" "sbx antwortet nicht — übersprungen"
  elif [ -z "$(template_id)" ]; then
    melde 2 "✗" "kein Template '$IMAGE' im Store — 'sbx-claude build --force'"
  else
    melde 0 "✓" "Template liegt im Store"
  fi

  zeile "--- 3. Sandbox gegen Image ---"
  if ! sandbox_exists "$sandbox"; then
    melde 0 "·" "Sandbox '$sandbox' existiert noch nicht — 'sbx-claude up' legt sie an"
  else
    local stand zustand quelle
    stand="$(sandbox_stand "$sandbox")"
    zustand="${stand%% *}"
    quelle="${stand##* }"
    case "$zustand" in
      aktuell)
        if [ "$quelle" = beobachtet ]; then
          melde 0 "✓" "Sandbox läuft auf dem aktuellen Image (Stempel in der Box gelesen)"
        else
          melde 0 "✓" "Sandbox passt zum aktuellen Image (laut Notiz vom Anlegen)"
        fi
        ;;
      veraltet)
        melde 3 "✗" "Sandbox läuft auf einem ÄLTEREN Image — 'sbx-claude rm' und 'up'"
        zeile "      Ein neues Template erreicht eine bestehende Sandbox nicht."
        [ "$quelle" = notiert ] && zeile "      (Box gestoppt, Auskunft aus der Notiz vom Anlegen)"
        ;;
      ohne-stempel)
        melde 3 "✗" "Sandbox trägt keinen Stempel — aus einem alten Image, 'sbx-claude rm' und 'up'"
        ;;
      *)
        melde 0 "·" "Sandbox gestoppt und keine Notiz vorhanden — Stand unbekannt"
        zeile "      Sicherheit gibt 'sbx-claude shell' (startet sie) und dann erneut 'check'."
        ;;
    esac
  fi

  zeile "--- 4. Mounts gegen Konfiguration ---"
  if ! sandbox_exists "$sandbox"; then
    melde 0 "·" "keine Sandbox — übersprungen"
  else
    soll="$(gewuenschte_mounts "$projekt" | sort)"
    ist="$(aktuelle_mounts "$sandbox" | sort)"
    if [ -z "$ist" ]; then
      melde 0 "·" "Mounts nicht lesbar (sbx ls --json) — übersprungen"
    else
      fehlend="$(comm -23 <(printf '%s\n' "$soll") <(printf '%s\n' "$ist"))"
      ueberzaehlig="$(comm -13 <(printf '%s\n' "$soll") <(printf '%s\n' "$ist"))"
      if [ -z "$fehlend" ] && [ -z "$ueberzaehlig" ]; then
        melde 0 "✓" "eingehängte Ordner entsprechen der Konfiguration"
      else
        melde 3 "✗" "Sandbox passt nicht zur Konfiguration — 'sbx-claude rm' und 'up'"
        # while-read und nicht `for eintrag in $fehlend`: ein Projektpfad mit
        # Leerzeichen würde sonst in mehrere Zeilen zerfallen, und dann meldet
        # der Vergleich Unterschiede, die es nicht gibt.
        #
        # ⚠️  Prozess-Substitution, KEIN Here-String. `<<< "$fehlend"` legt eine
        #     temporäre Datei an und scheitert dort, wo /tmp nicht schreibbar
        #     ist ("cannot create temp file for here document"). Eine Pipe wäre
        #     ebenfalls falsch: Subshell, und `zeile` schriebe ins Leere.
        while IFS= read -r eintrag; do
          [ -n "$eintrag" ] && zeile "      fehlt in der Sandbox:  $eintrag"
        done < <(printf '%s\n' "$fehlend")
        while IFS= read -r eintrag; do
          [ -n "$eintrag" ] && zeile "      übrig in der Sandbox:  $eintrag"
        done < <(printf '%s\n' "$ueberzaehlig")
        zeile "      Grund: Workspaces sind nur beim Anlegen setzbar."
      fi
    fi
  fi

  zeile "--- 5. Rückkanal ---"
  if [ -d "$EVENTS_DIR" ]; then
    melde 0 "✓" "Ereignisordner vorhanden"
  else
    melde 1 "✗" "Ereignisordner fehlt — 'sbx-claude sync'"
  fi

  PRAEFIX_AUSGABE=""
  return 0
}

cmd_check() {
  local projekt sandbox
  projekt="$(projekt_wurzel "$PWD")"
  sandbox="$(sandbox_name "$projekt")"

  STUFE=0
  printf 'Projekt: %s\nSandbox: %s\n\n' "$projekt" "$sandbox"
  pruefe_stand "$sandbox" "$projekt"

  printf '\n'
  case "$STUFE" in
    0) info "Alles aktuell." ;;
    1) info "Billigste Abhilfe: sbx-claude sync" ;;
    2) info "Billigste Abhilfe: sbx-claude update" ;;
    *) info "Nötig: sbx-claude rm && sbx-claude up  (kostet die Anmeldung)" ;;
  esac
  return "$STUFE"
}

# Eine Zeile pro Sandbox: Name, Zustand, Image-Stand, Projektpfad.
# Wird von `status` und `update` benutzt — der Vergleich steht damit an genau
# einer Stelle, in sandbox_stand(). Vorher gab es ihn dreimal, mit drei leicht
# verschiedenen Formulierungen für dasselbe.
sandbox_zeile() {
  local sandbox="$1" stand zustand quelle pfad text
  stand="$(sandbox_stand "$sandbox")"
  zustand="${stand%% *}"
  quelle="${stand##* }"
  pfad="$(cat "$(pfad_notiz "$sandbox")" 2>/dev/null || echo '?')"

  case "$zustand" in
    aktuell)      text="Image aktuell" ;;
    veraltet)     text="ÄLTERES Image, rm+up" ;;
    ohne-stempel) text="ohne Stempel, rm+up" ;;
    *)            text="Stand unbekannt" ;;
  esac
  [ "$quelle" = notiert ] && text="$text (Notiz)"

  if sandbox_running "$sandbox"; then
    printf '%-34s %-9s %-26s %s\n' "$sandbox" "läuft" "$text" "$pfad"
  else
    printf '%-34s %-9s %-26s %s\n' "$sandbox" "gestoppt" "$text" "$pfad"
  fi
}

cmd_status() {
  local sandbox vorlage waechter gefunden=0

  # template_id endet immer mit 0 (es hat sein eigenes `|| true`), ein
  # `|| echo fehlt` würde also nie greifen — deshalb die Prüfung auf leer.
  vorlage="$(template_id)"
  [ -n "$vorlage" ] || vorlage="fehlt"
  if waechter_laeuft; then waechter="läuft"; else waechter="läuft NICHT"; fi

  printf 'Image:    %s\n' "$IMAGE"
  printf 'Template: %s\n' "$vorlage"
  printf 'Wächter:  %s\n' "$waechter"
  printf '\n'

  # Zeigt auch den Projektpfad — dafür gab es einmal ein eigenes `ls`. Zwei
  # Kommandos für dieselbe Auskunft sind eines zu viel.
  while IFS= read -r sandbox; do
    [ -n "$sandbox" ] || continue
    gefunden=1
    sandbox_zeile "$sandbox"
  done < <(sandboxes)
  [ "$gefunden" = 1 ] || info "Noch keine Projekt-Sandbox. 'sbx-claude up' legt die erste an."

  printf '\nRegistrierte MCP-Server auf dem Host:\n'
  sbx mcp ls 2>/dev/null || printf '  (nicht lesbar)\n'
}

cmd_update() {
  local sandbox stand zustand veraltet=0 pfad
  cmd_build --force

  printf '\n'
  info "Ein neues Template erreicht bestehende Sandboxes NICHT. Stand:"
  while IFS= read -r sandbox; do
    [ -n "$sandbox" ] || continue
    printf '  '
    sandbox_zeile "$sandbox"
    stand="$(sandbox_stand "$sandbox")"
    zustand="${stand%% *}"
    case "$zustand" in
      veraltet|ohne-stempel) veraltet=1 ;;
    esac
  done < <(sandboxes)

  if [ "$veraltet" = 1 ]; then
    printf '\n'
    warn "Die als veraltet gemeldeten Sandboxes bekommen das neue Image erst nach"
    warn "'sbx-claude rm' und 'up' IM JEWEILIGEN PROJEKT — und das kostet dort die"
    warn "Claude-Anmeldung. Der Reihe nach:"
    while IFS= read -r sandbox; do
      [ -n "$sandbox" ] || continue
      stand="$(sandbox_stand "$sandbox")"
      case "${stand%% *}" in
        veraltet|ohne-stempel)
          pfad="$(cat "$(pfad_notiz "$sandbox")" 2>/dev/null || echo '?')"
          warn "  cd '$pfad' && sbx-claude rm && sbx-claude up"
          ;;
      esac
    done < <(sandboxes)
  fi
}

cmd_shell() {
  local projekt sandbox
  projekt="$(projekt_wurzel "${1:-$PWD}")"
  sandbox="$(sandbox_name "$projekt")"
  sandbox_exists "$sandbox" || die "Keine Sandbox '$sandbox'. Zuerst 'sbx-claude up'."
  sbx exec -it -w "$projekt" "$sandbox" bash
}

cmd_allow() {
  local host="${1:-}" projekt sandbox
  [ -n "$host" ] || die "Aufruf: sbx-claude allow <host>"
  projekt="$(projekt_wurzel "$PWD")"
  sandbox="$(sandbox_name "$projekt")"
  sandbox_exists "$sandbox" || die "Keine Sandbox '$sandbox'. Zuerst 'sbx-claude up'."
  sbx policy allow network --sandbox "$sandbox" "$host"
  info "'$host' für '$sandbox' freigegeben."
  info "Dauerhaft: als EXTRA_HOSTS in $CONFIG_FILE eintragen."
}

cmd_rm() {
  local sandbox projekt liste=()

  if [ "${1:-}" = "--all" ]; then
    while IFS= read -r sandbox; do
      [ -n "$sandbox" ] && liste+=("$sandbox")
    done < <(sandboxes)
    [ "${#liste[@]}" -gt 0 ] || { info "Keine Projekt-Sandbox vorhanden."; return 0; }
  else
    projekt="$(projekt_wurzel "${1:-$PWD}")"
    sandbox="$(sandbox_name "$projekt")"
    sandbox_exists "$sandbox" || { info "Keine Sandbox '$sandbox' vorhanden."; return 0; }
    liste=("$sandbox")
  fi

  warn "Entfernt werden: ${liste[*]}"
  warn "Das kostet: die Claude-Anmeldung, alles zur Laufzeit Installierte und"
  warn "die Sitzungshistorie. Deine Projektdateien bleiben — die liegen auf dem Host."
  read -r -p "Wirklich entfernen? [j/N] " antwort
  case "$antwort" in j|J|ja|Ja) ;; *) info "abgebrochen."; return 0 ;; esac

  for sandbox in "${liste[@]}"; do
    sbx rm --force "$sandbox" || warn "'$sandbox' liess sich nicht entfernen."
    # Die Stempel-Notiz muss mit weg, sonst behauptet `status` für eine nicht
    # mehr existierende Box weiter einen Stand. Die Pfad-Notiz bleibt bewusst:
    # sie trägt die Namenskollision und gilt auch für die nächste Box hier.
    rm -f "$(notiz_stempel "$sandbox")"
  done
  info "fertig. 'sbx-claude up' legt im Projekt eine frische Sandbox an."
}

# --- Der Wächter -------------------------------------------------------------

waechter_laeuft() {
  # Zwei Wege, weil es zwei Startarten gibt: der LaunchAgent meldet sich bei
  # launchctl, ein `sbx-claude watch` im Vordergrund nur als Prozess. Gesucht
  # wird der volle Skriptpfad — ein blosses "watch" träfe auch fremde Prozesse.
  if launchctl list "$AGENT_LABEL" >/dev/null 2>&1; then
    return 0
  fi
  if pgrep -f "$WATCH_SKRIPT" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

cmd_watch() {
  [ -x "$WATCH_SKRIPT" ] || die "Wächter-Skript fehlt oder ist nicht ausführbar: $WATCH_SKRIPT"
  mkdir -p "$EVENTS_DIR"
  exec "$WATCH_SKRIPT" "$EVENTS_DIR"
}

waechter_installieren() {
  mkdir -p "$HOME/Library/LaunchAgents" "$EVENTS_DIR"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '  <key>Label</key><string>%s</string>\n' "$AGENT_LABEL"
    printf '%s\n' '  <key>ProgramArguments</key>'
    printf '%s\n' '  <array>'
    printf '    <string>%s</string>\n' "$WATCH_SKRIPT"
    printf '    <string>%s</string>\n' "$EVENTS_DIR"
    printf '%s\n' '  </array>'
    printf '%s\n' '  <key>RunAtLoad</key><true/>'
    printf '%s\n' '  <key>KeepAlive</key><true/>'
    printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$STATE_DIR/watch.log"
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } > "$AGENT_PLIST"

  launchctl unload "$AGENT_PLIST" 2>/dev/null || true
  if launchctl load "$AGENT_PLIST" 2>/dev/null; then
    info "Wächter als LaunchAgent eingerichtet ($AGENT_LABEL)."
    info "Er startet ab jetzt bei jeder Anmeldung. Protokoll: $STATE_DIR/watch.log"
  else
    warn "launchctl load fehlgeschlagen. Zum Zuschauen: sbx-claude watch"
  fi
}

cmd_install() {
  mkdir -p "$(dirname "$BIN_LINK")" "$STATE_DIR" "$EVENTS_DIR"
  ln -sfn "$SCRIPT_PATH" "$BIN_LINK"
  info "Symlink gesetzt: $BIN_LINK -> $SCRIPT_PATH"
  case ":$PATH:" in
    *":$(dirname "$BIN_LINK"):"*) ;;
    *) warn "$(dirname "$BIN_LINK") liegt nicht auf dem PATH. In deine Shell-Konfiguration:"
       warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac

  if [ "${1:-}" = "--watcher" ]; then
    waechter_installieren
  else
    info "Ohne Wächter kommen keine Desktop-Meldungen an."
    info "Einrichten mit: sbx-claude install --watcher"
  fi
}

# --- doctor ------------------------------------------------------------------

cmd_doctor() {
  local werkzeug fehlt=0

  printf '=== Host-Werkzeuge ===\n'
  for werkzeug in sbx docker git shasum; do
    if command -v "$werkzeug" >/dev/null 2>&1; then
      printf '  ✓ %s\n' "$werkzeug"
    else
      printf '  ✗ %s fehlt\n' "$werkzeug"
      fehlt=1
    fi
  done
  for werkzeug in terminal-notifier osascript fswatch; do
    if command -v "$werkzeug" >/dev/null 2>&1; then
      printf '  ✓ %s\n' "$werkzeug"
    else
      printf '  · %s fehlt (optional)\n' "$werkzeug"
    fi
  done

  printf '\n=== Skript und Symlink ===\n'
  printf '  Skript:     %s\n' "$SCRIPT_PATH"
  printf '  Dockerfile: %s\n' "$DOCKERFILE"
  if [ -L "$BIN_LINK" ]; then
    printf '  ✓ Symlink:  %s -> %s\n' "$BIN_LINK" "$(aufloesen "$BIN_LINK")"
  else
    printf '  ✗ kein Symlink in %s — "sbx-claude install"\n' "$(dirname "$BIN_LINK")"
  fi

  printf '\n=== Konfiguration ===\n'
  if [ -f "$CONFIG_FILE" ]; then
    printf '  ✓ %s\n' "$CONFIG_FILE"
  else
    printf '  · keine Konfiguration (%s) — Standardwerte gelten\n' "$CONFIG_FILE"
  fi
  printf '  Berechtigungsmodus: %s\n' "$PERMISSION_MODE"
  printf '  git-Rückfragen für: %s Verben\n' "${#GIT_ASK_VERBEN[@]}"
  printf '  Meldeschwelle:      %s s\n' "$NOTIFY_SCHWELLE"

  printf '\n=== Benachrichtigung ===\n'
  if [ -d "$EVENTS_DIR" ]; then
    printf '  ✓ Ereignisordner: %s\n' "$EVENTS_DIR"
  else
    printf '  ✗ Ereignisordner fehlt: %s\n' "$EVENTS_DIR"
  fi
  if waechter_laeuft; then
    printf '  ✓ Wächter läuft\n'
  else
    printf '  ✗ Wächter läuft nicht — "sbx-claude install --watcher"\n'
  fi

  printf '\n=== Skills ===\n'
  if share_skills_aktiv; then
    printf '  ✓ feature.shareSkills ist AN\n'
    printf '  ⚠ Der Store ist maschinenweit und read-write. Auch fremde Sandboxes\n'
    printf '    hängen ihn ein. Für misstrauische Projekte: ISOLATE_SKILLS=1\n'
  else
    printf '  · feature.shareSkills ist AUS — globale Skills kommen nicht mit\n'
    printf '    (sbx-claude up fragt einmal, ob es eingeschaltet werden soll)\n'
  fi

  printf '\n=== GitHub-Token ===\n'
  if sbx secret ls 2>/dev/null | grep -qi github; then
    printf '  ✓ github-Geheimnis bei sbx hinterlegt\n'
    printf '  ⚠ Ein voller Token darf schreiben und löschen. Die git-Rückfragen\n'
    printf '    sind eine Bremse gegen Versehen, keine Grenze.\n'
  else
    printf '  · kein github-Geheimnis. push und gh scheitern. Hinterlegen mit:\n'
    printf '      gh auth token | sbx secret set github\n'
  fi

  printf '\n=== Git-Identität ===\n'
  printf '  user.name:  %s\n' "$(git config --global user.name  2>/dev/null || echo '(fehlt)')"
  printf '  user.email: %s\n' "$(git config --global user.email 2>/dev/null || echo '(fehlt)')"

  printf '\n=== Projekt-Sandboxes ===\n'
  local sandbox pfad gefunden=0
  while IFS= read -r sandbox; do
    [ -n "$sandbox" ] || continue
    gefunden=1
    pfad="$(cat "$(pfad_notiz "$sandbox")" 2>/dev/null || echo '?')"
    printf '  %-38s %s\n' "$sandbox" "$pfad"
  done < <(sandboxes)
  [ "$gefunden" = 1 ] || printf '  noch keine — "sbx-claude up" legt die erste an\n'

  [ "$fehlt" = 0 ] || { printf '\n'; die "Es fehlen Host-Werkzeuge (siehe oben)."; }
}

# --- Hilfe und Verteilung ----------------------------------------------------

usage() {
  # printf statt Here-Doc: Here-Docs brauchen eine Temp-Datei, und die ist in
  # einer Sandbox nicht überall schreibbar.
  printf '%s\n' \
    'sbx-claude — eine Claude-Sandbox pro Projekt, alle aus einem Image' \
    '' \
    'Aufruf: sbx-claude <kommando> [argument]' \
    '' \
    '  up [pfad]         Sandbox des Projekts sicherstellen und Claude starten' \
    '  sync [pfad]       Netz, Config, Skills, Settings erneut anwenden' \
    '  check             passt alles zusammen? Exitcode = Dringlichkeit' \
    '  status            alle Projekt-Sandboxes mit Image-Stand und Pfad' \
    '  shell [pfad]      bash in der Sandbox des Projekts' \
    '  allow <host>      Netz-Host einmalig freigeben' \
    '  build [--force]   Image bauen und in den sbx-Store laden' \
    '  update            neu bauen und sagen, welche Sandbox veraltet ist' \
    '  rm [pfad|--all]   Sandbox(es) entfernen (kostet die Anmeldung)' \
    '  watch             Wächter im Vordergrund (macht die Meldungen)' \
    '  install [--watcher]  Symlink nach ~/.local/bin, optional LaunchAgent' \
    '  doctor            alles prüfen und benennen' \
    '' \
    'Das Wichtigste in drei Sätzen:' \
    '  Jedes Projekt hat seine eigene Sandbox, alle aus demselben Image.' \
    '  Ein neues Image erreicht bestehende Sandboxes NICHT — siehe update.' \
    '  Es fragt nur bei git und bei wenigen unumkehrbaren Befehlen.' \
    ''
}

case "${1:-}" in
  up)      shift; require_tools; load_config; cmd_up      "$@" ;;
  sync)    shift; require_tools; load_config; cmd_sync    "$@" ;;
  check)   shift; require_tools; load_config; cmd_check   "$@" ;;
  status)  shift; require_tools; load_config; cmd_status  "$@" ;;
  shell)   shift; require_tools; load_config; cmd_shell   "$@" ;;
  allow)   shift; require_tools; load_config; cmd_allow   "$@" ;;
  build)   shift; require_tools; load_config; cmd_build   "$@" ;;
  update)  shift; require_tools; load_config; cmd_update  "$@" ;;
  rm)      shift; require_tools; load_config; cmd_rm      "$@" ;;
  watch)   shift;                load_config; cmd_watch   "$@" ;;
  install) shift;                load_config; cmd_install "$@" ;;
  doctor)  shift;                load_config; cmd_doctor  "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unbekanntes Kommando '$1'. 'sbx-claude help' zeigt die Übersicht." ;;
esac
