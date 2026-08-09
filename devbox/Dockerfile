# =============================================================================
# devbox — Basis-Image für eine Claude-Sandbox mit Docker Sandboxes (sbx)
#
# Dieses Image ist die "Werkstatt", in der der Agent später arbeitet. Es wird
# EINMAL pro Rechner gebaut und danach als sbx-Template registriert; aus dem
# Template entstehen beliebig viele Sandboxes.
#
#   Dockerfile  --docker build-->  Image  --sbx template load-->  Template
#                                                                    |
#                                                            sbx create -t
#                                                                    v
#                                                                 Sandbox
#
# Gebaut wird als root, gelaufen wird am Ende als der User `agent` — den bringt
# das Basisimage mit, und sbx startet den Agenten darunter.
# =============================================================================

FROM docker/sandbox-templates:claude-code-docker

USER root

# --- 1. Grundausstattung aus apt ---------------------------------------------
# ca-certificates/curl/gnupg : brauchen wir, um weiter unten fremde apt-Repos
#                              (GitHub CLI, NodeSource) sauber einzubinden.
# git                        : der Agent committet und pusht aus der Sandbox.
# build-essential            : gcc, g++, make und die C-Header. PFLICHT, nicht
#                              optional: Python 3.14 ist so neu, dass viele
#                              Pakete noch kein fertiges Wheel dafür anbieten
#                              und aus dem Quellcode gebaut werden müssen.
#                              Ohne dieses Paket bricht `pip install` dort mit
#                              "command 'gcc' failed" ab. Gleiches gilt für
#                              npm-Pakete mit nativem Anteil (bcrypt, sharp).
# jq                         : JSON auf der Kommandozeile filtern. Fast alles
#                              moderne Tooling (`gh api`, `npm ... --json`)
#                              antwortet in JSON.
# ripgrep                    : schnelles rekursives Suchen, respektiert
#                              .gitignore und überspringt node_modules.
# less                       : Pager, den git für `git log`/`git diff` erwartet.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        build-essential \
        jq \
        ripgrep \
        less \
    && rm -rf /var/lib/apt/lists/*

# --- 2. GitHub CLI (gh) ------------------------------------------------------
# Defensiv installiert: manche Varianten des Basisimages bringen `gh` schon mit,
# garantiert ist es nicht. `command -v` prüft das, der Rest läuft nur im
# Bedarfsfall. Der Schlüssel wird über die moderne signed-by-Methode in einen
# eigenen Keyring gelegt statt über das veraltete `apt-key`.
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

# --- 3. uv ------------------------------------------------------------------
# uv ist unser Python-Werkzeug: es installiert Interpreter, verwaltet
# virtuelle Umgebungen und installiert CLI-Tools. Wir brauchen es weiter unten
# gleich dreimal, also kommt es zuerst.
#
# Installiert nach /usr/local/bin, damit es sowohl für den Build (root) als auch
# zur Laufzeit (agent) auf dem PATH liegt. Auch hier defensiv, falls das
# Basisimage uv bereits mitbringt.
RUN command -v uv >/dev/null 2>&1 || ( \
        export UV_INSTALL_DIR=/usr/local/bin \
        && curl -LsSf https://astral.sh/uv/install.sh | sh \
    )

# --- 4. Node.js und pnpm -----------------------------------------------------
# Das Basisimage bringt eine Node-Version für Claude Code mit; wir setzen
# zusätzlich Node 24 (aktuelle LTS-Linie) aus dem NodeSource-Repo, damit
# `node`, `npm` und `corepack` alle dieselbe, vorhersagbare Version sind.
#
# pnpm wird als ganz normales globales npm-Paket installiert — bewusst NICHT
# über corepack. Grund (haben wir uns beim Bauen eingefangen und nachgemessen):
# `corepack prepare --activate` legt seine Aktivierung im Cache des BAU-Users
# ab, also unter /root. Zur Laufzeit läuft aber der User `agent`. Der sieht
# davon nichts, fällt auf "neueste Version" zurück und lädt beim ersten
# `pnpm`-Aufruf eine andere Version aus dem Netz nach:
#
#   $ pnpm --version
#   ! Corepack is about to download .../pnpm-11.21.0.tgz
#   11.21.0        <- nicht die Version, die wir festgelegt hatten
#
# Ein globales `npm install -g` landet dagegen in /usr/local/lib/node_modules
# und ist damit für jeden User sichtbar und fest.
#
# Andere pnpm-Version gewünscht? Genau diese eine Zeile ändern und neu bauen.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g pnpm@10.11.0

# --- 5. Python 3.10 / 3.12 / 3.14 -------------------------------------------
# Drei Interpreter parallel, installiert von uv in ein gemeinsames,
# world-readable Verzeichnis. UV_PYTHON_INSTALL_DIR wird als ENV gesetzt, damit
# auch der Laufzeit-User `agent` sie dort findet.
#
# Der Clou: Ein Projekt mit einer `.python-version`-Datei bekommt seine Version
# automatisch — uv liest die Datei und wählt den passenden Interpreter. Die
# Symlinks unten legen nur fest, was bei einem blanken `python` herauskommt.
#
# /usr/local/bin steht auf dem PATH VOR /usr/bin. Damit gewinnt unser 3.12 für
# Shell und Agent, während /usr/bin/python3 für die apt-Werkzeuge des Systems
# unangetastet bleibt.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN mkdir -p "$UV_PYTHON_INSTALL_DIR" \
    && uv python install 3.10 3.12 3.14 \
    && chmod -R a+rX "$UV_PYTHON_INSTALL_DIR" \
    && PYBIN="$(uv python find 3.12)" \
    && ln -sf "$PYBIN" /usr/local/bin/python3 \
    && ln -sf "$PYBIN" /usr/local/bin/python

# --- 6. poetry und ruff ------------------------------------------------------
# Beide sind eigenständige CLI-Werkzeuge, keine Projekt-Abhängigkeiten. `uv tool
# install` legt für jedes eine eigene isolierte Umgebung an, sodass sich ihre
# Abhängigkeiten nicht gegenseitig oder mit einem Projekt beißen.
#
# UV_TOOL_DIR  : wo die Umgebungen liegen (geteilt, world-readable)
# UV_TOOL_BIN_DIR: wohin die ausführbaren Dateien verlinkt werden — /usr/local/bin,
#                  damit `poetry` und `ruff` ohne PATH-Bastelei direkt laufen.
# pip ist nicht extra installiert: es kommt mit jedem der drei CPython-Interpreter mit.
ENV UV_TOOL_DIR=/opt/uv-tools
RUN mkdir -p "$UV_TOOL_DIR" \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install poetry \
    && UV_TOOL_BIN_DIR=/usr/local/bin uv tool install ruff \
    && chmod -R a+rX "$UV_TOOL_DIR"

# --- 7. Playwright -----------------------------------------------------------
# Chromium landet im gemeinsamen, world-readable Verzeichnis /ms-playwright,
# damit der Laufzeit-User `agent` ihn benutzen kann, ohne beim ersten Start
# mehrere hundert MB nachzuladen.
#
# `install-deps` darf mit `|| true` weich fehlschlagen: für sehr neue
# Ubuntu-Versionen hat Playwright nicht immer eine gepflegte Paketliste. Der
# Browser läuft in der Praxis trotzdem, weil das Basisimage die nötigen
# Bibliotheken bereits mitbringt. Falls doch ein Start fehlschlägt, gehört die
# fehlende Bibliothek oben in Schritt 1.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g @playwright/test@latest \
    && (playwright install-deps chromium || true) \
    && playwright install chromium \
    && chmod -R a+rX /ms-playwright

# --- 8. Safe Chain (Schutz vor Malware in Paketen) --------------------------
# Wovor das schützt: Bei einem Supply-Chain-Angriff wird ein etabliertes Paket
# übernommen und eine vergiftete Version veröffentlicht. Beim `npm install`
# läuft dann ein postinstall-Script mit deinen Rechten und liest Tokens, Keys
# und Zugangsdaten aus. Du merkst nichts — das Paket funktioniert ja.
#
# Safe Chain schiebt sich zwischen dich und die Registry und prüft jedes Paket
# (auch die tiefen Abhängigkeiten, die du nie selbst tippst) gegen eine
# Malware-Datenbank, bevor es auf der Platte landet.
#
# Wir bauen die Shims BEWUSST selbst statt sie vom Installer erzeugen zu lassen:
# so ist genau sichtbar, was passiert, und der Schutz lässt sich über eine
# einzige PATH-Zeile an- und abschalten (siehe Schritt 9).
#
# Die sed-Zeile in jedem Shim entfernt das Shim-Verzeichnis aus dem PATH, bevor
# das echte Werkzeug aufgerufen wird. Ohne das würde `aikido-npm` intern wieder
# unseren `npm`-Shim finden und sich endlos selbst aufrufen.
RUN npm install -g @aikidosec/safe-chain \
    && mkdir -p /opt/safe-chain/shims \
    && for tool in npm npx pnpm pnpx uv uvx; do \
         printf '%s\n' \
           '#!/bin/sh' \
           '# Von devbox erzeugter Safe-Chain-Shim — siehe devbox/Dockerfile, Schritt 8.' \
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

# --- 9. Persistente Umgebung -------------------------------------------------
# /etc/sandbox-persistent.sh wird von sbx VOR JEDEM bash-Aufruf in der Sandbox
# gesourct. Alles, was hier im Image hineingeschrieben wird, überlebt auch ein
# `sbx rm` und das Neuanlegen der Sandbox. (Was zur Laufzeit hineingeschrieben
# wird, überlebt das NICHT.)
#
# Immer anhängen (>>), niemals überschreiben — das Basisimage hat dort schon
# eigene Zeilen stehen.
#
# Der Safe-Chain-Schalter: Ist DEVBOX_SAFE_CHAIN nicht gesetzt, gilt 1 (an).
# Zum Abschalten in der Sandbox:
#   echo 'export DEVBOX_SAFE_CHAIN=0' >> /etc/sandbox-persistent.sh
RUN { \
      echo ''; \
      echo '# --- devbox ---------------------------------------------------'; \
      echo 'export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright'; \
      echo 'export UV_PYTHON_INSTALL_DIR=/opt/uv-python'; \
      echo 'export UV_TOOL_DIR=/opt/uv-tools'; \
      echo 'export PNPM_HOME="$HOME/.local/share/pnpm"'; \
      echo ''; \
      echo '# Diese Datei wird bei verschachtelten Shells mehrfach gesourct.'; \
      echo '# Ohne Prüfung würde derselbe Eintrag den PATH jedes Mal weiter'; \
      echo '# aufblähen — deshalb hängen wir nur an, was noch nicht drin ist.'; \
      echo 'devbox_pfad_voranstellen() {'; \
      echo '  case ":$PATH:" in'; \
      echo '    *":$1:"*) ;;'; \
      echo '    *) PATH="$1:$PATH"; export PATH ;;'; \
      echo '  esac'; \
      echo '}'; \
      echo 'devbox_pfad_voranstellen "$PNPM_HOME"'; \
      echo ''; \
      echo '# Safe Chain: prüft Pakete auf Malware, bevor sie installiert werden.'; \
      echo '# Abschalten mit: export DEVBOX_SAFE_CHAIN=0'; \
      echo 'if [ "${DEVBOX_SAFE_CHAIN:-1}" = "1" ]; then'; \
      echo '  devbox_pfad_voranstellen /opt/safe-chain/shims'; \
      echo 'fi'; \
    } >> /etc/sandbox-persistent.sh

# Ab hier läuft alles als der unprivilegierte Laufzeit-User.
USER agent
