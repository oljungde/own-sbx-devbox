#!/usr/bin/env bash
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
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/solobox"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

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
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$SCRIPT_DIR"

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
provision() {
  local mounts=() d flags=() eintrag pfad

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

  # sbx bricht ab, wenn ein einzuhängender Ordner nicht existiert. Auf frisch
  # eingerichteten Rechnern fehlt z.B. ~/.claude/workflows — also legen wir die
  # fehlenden Ordner still an, statt den Start scheitern zu lassen.
  for d in "${CLAUDE_SHARED[@]}"; do
    mkdir -p "$HOME/.claude/$d"
    # Die Klammern um $d sind kein Zierrat: in zsh würde "$HOME/.claude/$d:ro"
    # als History-Modifier ":r" gelesen und ergäbe "…/agentso".
    mounts+=("$HOME/.claude/${d}:ro")
  done

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
    "${ROOTS[@]}" \
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
  local vermerk
  vermerk="$(recorded_hash)"
  if [ -z "$(template_id)" ]; then
    info "kein Template '$IMAGE' im sbx-Store — ich baue es jetzt."
    cmd_build
  elif [ -z "$vermerk" ]; then
    # Template da, aber kein Merkzettel: typisch, wenn es von Hand geladen wurde
    # (docker save + sbx template load). Kein Grund zur Warnung — wir wissen
    # schlicht nicht, aus welchem Dockerfile es stammt.
    info "Template vorhanden, Herkunft unbekannt (kein Merkzettel im State-Ordner)."
  elif [ "$(current_hash)" != "$vermerk" ]; then
    warn "Das Dockerfile hat sich seit dem letzten Bau geändert."
    warn "Die Sandbox startet auf dem ALTEN Template. Neu bauen: 'solobox update'."
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
  local id
  id="$(template_id)"

  echo "--- Template ---"
  if [ -n "$id" ]; then
    printf '  ✓ %s  (ID %s)\n' "$IMAGE" "$id"
    local vermerk_bau; vermerk_bau="$(recorded_hash)"
    if [ -z "$vermerk_bau" ]; then
      echo "    Herkunft unbekannt (kein Merkzettel) — 'solobox build --force' legt ihn an"
    elif [ "$(current_hash)" = "$vermerk_bau" ]; then
      echo "    Dockerfile unverändert seit dem letzten Bau"
    else
      echo "    ! Dockerfile hat sich geändert — 'solobox update'"
    fi
  else
    echo "  ✗ kein Template '$IMAGE' im sbx-Store"
    echo "    Entweder noch nicht gebaut ('solobox build') — oder du bist nicht"
    echo "    angemeldet ('sbx login'). Beides sieht von hier gleich aus."
  fi

  echo "--- Die Sandbox ---"
  if sandbox_exists; then
    local zustand vermerk
    zustand="$(sbx ls 2>/dev/null | awk -v n="$SANDBOX" 'NR>1 && $1==n { print $3; exit }' || true)"
    vermerk="$(recorded_sandbox_image)"
    if [ -z "$vermerk" ]; then
      vermerk="Template unbekannt"
    elif [ "$vermerk" = "$id" ]; then
      vermerk="Template aktuell"
    else
      vermerk="Template VERALTET ($vermerk) — 'solobox update' erklärt, was zu tun ist"
    fi
    printf '  %-10s %-9s %s\n' "$SANDBOX" "${zustand:-?}" "$vermerk"

    # Die Wurzeln stehen hier, weil sie NUR beim Anlegen gesetzt wurden — nach
    # ein paar Wochen weiß niemand mehr auswendig, was die Sandbox sieht.
    echo "  Eingehängt:"
    sbx ls 2>/dev/null \
      | awk -v n="$SANDBOX" -F'   +' 'NR>1 && $1 ~ ("^" n) { print $NF }' \
      | tr ',' '\n' | sed 's/^ */    /' || true
  else
    echo "  (keine — 'solobox up' im gewünschten Projekt)"
  fi

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

  echo "--- Template ---"
  local vermerk; vermerk="$(recorded_hash)"
  if [ -z "$vermerk" ]; then
    echo "  · kein Merkzettel — Herkunft des Templates unbekannt"
    echo "    (typisch nach 'docker save' + 'sbx template load' von Hand)"
  elif [ "$(current_hash)" = "$vermerk" ]; then
    echo "  ✓ Template ist auf dem Stand des Dockerfiles"
  else
    echo "  ! Dockerfile hat sich geändert — 'solobox build'"
  fi

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
    'Vorlage: solobox/solobox.conf.example'
}

# --- Einstiegspunkt ----------------------------------------------------------

case "${1:-}" in
  up)      shift; require_tools; load_config; cmd_up      "$@" ;;
  build)   shift; require_tools; load_config; cmd_build   "$@" ;;
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
