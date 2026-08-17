# =============================================================================
# sbx-claude — Bauanleitung für das EINE Image, aus dem alle Projekt-Sandboxes
# entstehen (Variante 3)
#
# Der Unterschied zu den beiden anderen Varianten steckt in einem Satz: Hier
# bekommt jedes Projekt seine eigene Sandbox, aber alle aus demselben Image.
# Daraus folgt die Ausstattungsentscheidung, und sie geht anders aus als man
# zunächst denkt:
#
#   Ein neues Template erreicht BESTEHENDE Sandboxes nicht. Fehlt dir später ein
#   Werkzeug, musst du das Image neu bauen UND jede Projekt-Sandbox löschen, neu
#   anlegen und dich neu anmelden. Bei zehn Projekten ist "ich lege später nach"
#   damit kein kleiner Schritt, sondern ein Nachmittag.
#
#   Deshalb ist dieses Image absichtlich VOLL ausgestattet. In solobox, wo es
#   genau eine Sandbox gibt, kostet Nachlegen fast nichts — hier kostet es
#   N-mal. Der einzige wirklich schwere Posten ist Playwright mit Chromium
#   (etwa 1,5–2 GB); ein zusätzlicher Python liegt bei rund 150 MB, poetry und
#   ruff bei wenigen zehn MB.
#
# Ein Ding liegt hier, das es in den anderen Varianten nicht gibt:
#   `sbx-claude-notify` — schreibt Ereignisse in den Rückkanal, damit die
#   Benachrichtigung im Container überhaupt funktionieren kann.
# Es gehört ins IMAGE und nicht in einen Mount: ein Hook muss auch dann
# funktionieren, wenn vom Host gerade nichts erreichbar ist.
# =============================================================================

FROM docker/sandbox-templates:claude-code-docker

USER root

# --- Grundwerkzeug -----------------------------------------------------------
# `jq` ist hier Pflicht, nicht Kür: Claude Code schickt Hook-Eingaben als JSON
# auf stdin, und beide Hooks dieses Images lesen sie damit. Fehlt jq, scheitert
# der Hook — mit einer Meldung, die nach einem Hook-Fehler aussieht und nicht
# nach einem fehlenden Werkzeug.
#
# `build-essential` ist ebenfalls Pflicht: Python 3.14 ist jung, für viele
# Pakete gibt es noch kein fertiges Wheel, und dann wird aus dem Quellcode
# gebaut. Ohne gcc bricht `pip install` mit "command 'gcc' failed" ab. Gleiches
# gilt für npm-Pakete mit nativem Anteil (bcrypt, sharp).
#
# `ripgrep` und `less` bringt das Basis-Image schon mit — prüfbar mit
#   docker run --rm sbx-claude/base:latest bash -lc 'command -v rg less'
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    gnupg \
    curl \
    git \
    jq \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI --------------------------------------------------------------
# Defensiv: manche Ausgaben des Basis-Images bringen `gh` mit, garantiert ist es
# nicht. Der Schlüssel kommt über die moderne signed-by-Methode in einen eigenen
# Keyring statt über das veraltete `apt-key`.
#
# Angemeldet wird `gh` hier NICHT. Der Token liegt auf dem Host in sbx'
# Geheimnis-Speicher (`sbx secret set github`), und sbx' Proxy setzt ihn in
# ausgehende Anfragen ein — er betritt das Container-Dateisystem nie.
RUN command -v gh >/dev/null 2>&1 || ( \
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
             > /etc/apt/sources.list.d/github-cli.list \
        && apt-get update \
        && apt-get install -y --no-install-recommends gh \
        && rm -rf /var/lib/apt/lists/* \
    )

# --- uv ----------------------------------------------------------------------
# Der Python-Teil weiter unten arbeitet mit uv. Nach /usr/local/bin, damit es
# sowohl für den Bau (root) als auch zur Laufzeit (agent) auf dem PATH liegt.
#
# Zum Verständnis: Was hier beim BAUEN aus dem Netz kommt, unterliegt NICHT der
# sbx-Netzregel. Die gilt für die laufende Sandbox — beim Bauen redet der
# Docker-Daemon, nicht der Container.
RUN command -v uv >/dev/null 2>&1 || ( \
        export UV_INSTALL_DIR=/usr/local/bin \
        && curl -LsSf https://astral.sh/uv/install.sh | sh \
    )

# --- Node.js 24 --------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- pnpm --------------------------------------------------------------------
# ⚠️  Bewusst NICHT über corepack. `corepack prepare pnpm@… --activate` sieht
#     sauberer aus, legt seine Aktivierung aber im Cache des BAU-Users (root)
#     unter /root/.cache/node/corepack ab. Zur Laufzeit läuft `agent`, kommt
#     dort nicht heran und lädt beim ersten Aufruf still eine andere Version
#     nach — nachgemessen beim Bauen dieses Repos:
#
#       $ pnpm --version
#       ! Corepack is about to download .../pnpm-11.21.0.tgz
#       11.21.0        <- nicht die festgelegte Version
#
#     `npm install -g` landet dagegen in /usr/local/lib/node_modules und gilt
#     für alle Benutzer fest.
#
# Andere pnpm-Version gewünscht? Genau diese eine Zeile ändern und neu bauen.
RUN npm install -g pnpm@10.11.0

# --- Lieferketten-Schutz: Aikido Safe Chain ----------------------------------
# Wovor das schützt: Bei einem Lieferketten-Angriff wird ein etabliertes Paket
# übernommen und eine vergiftete Version veröffentlicht. Beim `npm install`
# läuft dann ein postinstall-Script mit deinen Rechten und liest Tokens und
# Zugangsdaten aus. Du merkst nichts — das Paket funktioniert ja.
#
# ⚠️  Wir bauen SHIMS, keine Shell-Funktionen. Der Unterschied ist nicht
#     kosmetisch, sondern eine Sicherheitslücke — nachgemessen beim Bauen dieses
#     Repos: Eine Shell-Funktion existiert nur IN der Shell. Jeder Aufruf, der
#     `npm` als Programm startet, geht daran vorbei:
#
#       timeout 60 npm install boesartig     # timeout startet die Binärdatei
#       env npm install boesartig            # env ebenso
#       xargs -n1 npm install < liste        # xargs ebenso
#       sbx exec sbx-claude-x npm install …  # gar keine Shell dazwischen
#
#     Genau so ging das offizielle Testpaket `safe-chain-test` durch, während
#     derselbe Befehl ohne `timeout` blockiert wurde. Shims sind echte Dateien
#     auf dem PATH und greifen auch ohne Shell.
#
# Die sed-Zeile in jedem Shim nimmt das Shim-Verzeichnis aus dem PATH, BEVOR das
# echte Werkzeug läuft. Ohne das würde `aikido-npm` intern wieder unseren
# `npm`-Shim finden und sich endlos selbst aufrufen.
#
# Die Shims greifen nur zur LAUFZEIT: sie kommen erst über die PATH-Zeile in
# /etc/sandbox-persistent.sh zum Zug, die RUN-Schritte hier bauen ohne sie.
# Fehlt der aikido-Shim, fällt der Shim mit einer Warnung auf das echte Werkzeug
# zurück, statt den Befehl scheitern zu lassen. Die Prüfungen erreichen
# *.aikido.dev — der Host steht in der Erlaubnisliste des Wrappers.
RUN npm install -g @aikidosec/safe-chain \
    && mkdir -p /opt/safe-chain/shims \
    && for tool in npm npx pnpm pnpx uv uvx; do \
         printf '%s\n' \
           '#!/bin/sh' \
           '# Von sbx-claude erzeugter Safe-Chain-Shim — siehe v3/Dockerfile.' \
           '# Shim-Verzeichnis aus dem PATH nehmen, sonst ruft aikido-* uns erneut auf.' \
           'PATH="$(printf "%s" "$PATH" | sed -e "s|/opt/safe-chain/shims:||g")"' \
           'export PATH' \
           "if command -v aikido-$tool >/dev/null 2>&1; then" \
           "  exec aikido-$tool \"\$@\"" \
           'else' \
           "  echo \"Warnung: safe-chain fehlt — $tool läuft ungeschützt.\" >&2" \
           "  exec $tool \"\$@\"" \
           'fi' \
           > "/opt/safe-chain/shims/$tool"; \
       done \
    && chmod -R a+rx /opt/safe-chain/shims

# --- Python 3.10, 3.12 und 3.14 ----------------------------------------------
# Ein Image für alle Projekte heißt: mehrere Python-Versionen gleichzeitig. uv
# legt sie in ein gemeinsames, für alle lesbares Verzeichnis; über die
# ENV-Variable findet auch `agent` sie wieder — und wählt automatisch die
# passende, wenn ein Projekt eine .python-version mitbringt.
#
# Absichtlich nur Minor-Versionen, keine Patchlevel: im Kursmaterial ist eine
# lesbare, immer aktuelle Zeile mehr wert als ein bitgleicher Nachbau. Ob sich
# etwas geändert hat, erkennt der Wrapper am Text dieses Dockerfiles.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN mkdir -p "$UV_PYTHON_INSTALL_DIR" \
    && uv python install 3.10 3.12 3.14 \
    && chmod -R a+rX "$UV_PYTHON_INSTALL_DIR"

# Jede Version einzeln aufrufbar machen, 3.12 als Standard. /usr/local/bin steht
# auf dem PATH vor /usr/bin, diese Links gewinnen also gegen das System-Python —
# /usr/bin/python3 bleibt für apt & Co. unangetastet.
RUN ln -sf "$(uv python find 3.10)" /usr/local/bin/python3.10 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3.12 \
    && ln -sf "$(uv python find 3.14)" /usr/local/bin/python3.14 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python

# --- poetry und ruff ---------------------------------------------------------
# Eigenständige Werkzeuge, keine Projekt-Abhängigkeiten. `uv tool install` legt
# für jedes eine isolierte Umgebung an, damit sich ihre Abhängigkeiten nicht
# gegenseitig oder mit einem Projekt beißen. pip kommt mit jedem der drei
# Interpreter mit und braucht keine eigene Zeile.
ENV UV_TOOL_DIR=/opt/uv-tools
RUN mkdir -p "$UV_TOOL_DIR" \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install poetry \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install ruff \
    && chmod -R a+rX "$UV_TOOL_DIR"

# --- Playwright mit Chromium -------------------------------------------------
# Der schwere Posten, bewusst drin: siehe die Begründung im Kopf dieser Datei.
#
# Chromium landet im gemeinsamen, für alle lesbaren Cache /ms-playwright, damit
# `agent` es benutzen kann, ohne es erneut zu laden. @playwright/test kommt als
# @latest und nicht gepinnt: ältere Versionen kennen die Ubuntu-Ausgabe des
# Basis-Images teilweise nicht.
#
# `install-deps` darf scheitern (|| true): für diese Ubuntu-Ausgabe gibt es
# nicht immer eine gepflegte Playwright-Paketliste. Der Browser läuft in der
# Praxis trotzdem, weil die nötigen Bibliotheken im Basis-Image stecken. Tritt
# doch ein Startfehler auf, gehört die fehlende Bibliothek in den apt-Block oben.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g @playwright/test@latest \
    && (playwright install-deps chromium || true) \
    && playwright install chromium \
    && chmod -R a+rX /ms-playwright

# --- Playwright-MCP vorwärmen ------------------------------------------------
# Wandert nur in den globalen npm-Cache, damit ein späteres
# `npx @playwright/mcp@latest` sofort startet statt erst zu laden. Registriert
# wird der Server hier NICHT — MCP kommt über deine Plugins oder über
# `sbx mcp add`/`sbx mcp load` (siehe Kapitel 7).
RUN npm install -g @playwright/mcp@latest

# --- Dauerhafte Umgebung -----------------------------------------------------
# Alles, was an /etc/sandbox-persistent.sh angehängt wird, liest die Sandbox vor
# jedem bash-Aufruf ein. Weil es im Image steckt, überlebt es das Entfernen und
# Neuanlegen einer Sandbox. Immer anhängen (>>), nie überschreiben.
#
# Safe-Chain-Schalter: Ist SBX_CLAUDE_SAFE_CHAIN nicht gesetzt, gilt 1 (an).
# Abschalten in der laufenden Sandbox mit: export SBX_CLAUDE_SAFE_CHAIN=0
RUN { \
      echo ''; \
      echo '# --- sbx-claude -----------------------------------------------'; \
      echo 'export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright'; \
      echo 'export UV_PYTHON_INSTALL_DIR=/opt/uv-python'; \
      echo 'export UV_TOOL_DIR=/opt/uv-tools'; \
      echo 'export PNPM_HOME="$HOME/.local/share/pnpm"'; \
      echo ''; \
      echo '# Diese Datei wird bei verschachtelten Shells mehrfach gesourct.'; \
      echo '# Ohne Prüfung würde derselbe Eintrag den PATH jedes Mal weiter'; \
      echo '# aufblähen — deshalb hängen wir nur an, was noch nicht drin ist.'; \
      echo 'sbx_claude_pfad_voranstellen() {'; \
      echo '  case ":$PATH:" in'; \
      echo '    *":$1:"*) ;;'; \
      echo '    *) PATH="$1:$PATH"; export PATH ;;'; \
      echo '  esac'; \
      echo '}'; \
      echo 'sbx_claude_pfad_voranstellen "$PNPM_HOME"'; \
      echo ''; \
      echo '# Safe Chain: prüft Pakete auf Malware, bevor sie installiert werden.'; \
      echo '# Abschalten mit: export SBX_CLAUDE_SAFE_CHAIN=0'; \
      echo 'if [ "${SBX_CLAUDE_SAFE_CHAIN:-1}" = "1" ]; then'; \
      echo '  sbx_claude_pfad_voranstellen /opt/safe-chain/shims'; \
      echo 'fi'; \
    } >> /etc/sandbox-persistent.sh

# --- Der Benachrichtigungs-Hook ----------------------------------------------
# Er steht bewusst WEIT UNTEN: ein COPY entwertet den Build-Cache ab dieser
# Zeile. Eine Änderung am Hook soll das Python- und Chromium-Kapitel nicht neu
# bauen — Minuten, für eine kleine Textdatei.
#
# Und er steht bewusst im IMAGE statt in einem Mount: ein Hook muss auch dann
# funktionieren, wenn vom Host gerade nichts erreichbar ist. Was er zur Laufzeit
# noch braucht — Ereignisordner, Sandbox-Name und Schwelle —, bekommt er als
# ARGUMENTE aus der abgeleiteten settings.json. Diese Werte könnten hier auch
# nicht stehen: der Ereignisordner ist ein Host-Pfad, und der Sandbox-Name
# entsteht erst pro Projekt.
COPY hooks/notify.sh /usr/local/bin/sbx-claude-notify
RUN chmod a+rx /usr/local/bin/sbx-claude-notify

# --- Optional: gcloud CLI ----------------------------------------------------
# Bewusst nicht eingebaut. Wer es braucht, entfernt die Kommentarzeichen und
# baut neu (`sbx-claude update`) — und denkt daran, dass bestehende
# Projekt-Sandboxes das neue Template NICHT bekommen:
#
# RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
#     | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
# RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
#     > /etc/apt/sources.list.d/google-cloud-sdk.list
# RUN apt-get update && apt-get install -y google-cloud-cli \
#     && rm -rf /var/lib/apt/lists/*
#
# Dazu gehören zwei Hosts in EXTRA_HOSTS der Konfiguration:
#   packages.cloud.google.com   und   *.googleapis.com

# --- Stempel: woraus ist dieses Image entstanden? ----------------------------
# Damit `sbx-claude check` beantworten kann, ob eine laufende Sandbox noch zum
# aktuellen Dockerfile passt, trägt jedes Image seine Herkunft selbst mit sich:
# einmal als Label (vom Host lesbar) und einmal als Datei (aus der Sandbox
# lesbar). Ohne das bliebe nur eine Merkdatei auf dem Host — und die kann
# fehlen, verloren gehen oder auf einem anderen Rechner nie existiert haben.
#
# Bei einer Sandbox pro Projekt ist dieser Stempel WICHTIGER als in den anderen
# Varianten, nicht unwichtiger: Ein neues Template erreicht bestehende
# Sandboxes nie, und bei zehn Projekten merkt man das sonst monatelang nicht.
#
# Keine Zirkularität, auch wenn es so aussieht: Gehasht wird der TEXT dieses
# Dockerfiles. Der Wert kommt von außen über --build-arg und steht nirgends in
# der Datei, kann den eigenen Hash also nicht verändern.
#
# Dieser Block steht ganz am ENDE: Ein neuer Stempelwert entwertet den
# Build-Cache ab der Zeile, in der er zuerst benutzt wird. Weiter oben würde
# jede Dockerfile-Änderung das Chromium- und Python-Kapitel neu bauen.
ARG SBX_CLAUDE_STAMP=unbekannt
ARG SBX_CLAUDE_BASE_DIGEST=unbekannt
LABEL sbx-claude.dockerfile-sha=$SBX_CLAUDE_STAMP
LABEL sbx-claude.base-digest=$SBX_CLAUDE_BASE_DIGEST
RUN printf '%s\n' "$SBX_CLAUDE_STAMP" > /etc/sbx-claude-stamp \
    && printf '%s\n' "$SBX_CLAUDE_BASE_DIGEST" > /etc/sbx-claude-base-digest \
    && chmod a+r /etc/sbx-claude-stamp /etc/sbx-claude-base-digest

USER agent
