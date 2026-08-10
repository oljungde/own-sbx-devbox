# =============================================================================
# solobox — Bauanleitung für die eine Sandbox
#
# Was hier anders ist als in devbox/Dockerfile (Variante 1):
#
#   - DREI Pythons statt einem: 3.10, 3.12 und 3.14, mit 3.12 als Standard.
#     Eine einzige Sandbox bedient alle Projekte, und die haben nicht alle
#     dieselbe Python-Version.
#   - Playwright mit Chromium ist fest eingebaut. In Variante 1 war das
#     verzichtbar, weil man sich pro Profil eine Sandbox bauen konnte.
#   - Node 24 statt der Node-Version des Basis-Images.
#   - `jq` ist Pflicht, nicht Kür: deine globalen Hooks aus ~/.claude
#     lesen ihre Eingabe damit (siehe Kapitel 3).
#   - KEIN gcloud. Wer es braucht, kommentiert den Block am Ende ein.
#
# Wie man ein Dockerfile für sbx überhaupt schreibt, steht im devbox-Tutorial,
# Kapitel 2 und 3. Hier steht die fertige Fassung mit der Begründung, warum sie
# so aussieht.
# =============================================================================

FROM docker/sandbox-templates:claude-code-docker

USER root

# --- Grundwerkzeug -----------------------------------------------------------
# `git` braucht der Agent für alles, was nach `git`/`gh` aussieht.
# `jq` brauchen die Hooks: Claude Code schickt Hook-Eingaben als JSON auf stdin,
# und deine Hooks auf dem Host lesen sie mit jq. Fehlt jq, scheitert der Hook —
# und zwar mit einer Meldung, die nach einem Hook-Fehler aussieht, nicht nach
# einem fehlenden Werkzeug.
# `build-essential` ist PFLICHT, nicht Kür: Python 3.14 ist so neu, dass viele
# Pakete noch kein fertiges Wheel dafür anbieten und aus dem Quellcode gebaut
# werden müssen. Ohne gcc bricht `pip install` dort mit "command 'gcc' failed"
# ab — nachgemessen im fertigen Image, wo gcc sonst fehlt. Gleiches gilt für
# npm-Pakete mit nativem Anteil (bcrypt, sharp).
# `ca-certificates` und `gnupg` bleiben drin, weil jede spätere Fremdquelle
# (auch der auskommentierte gcloud-Block unten) sie voraussetzt.
# `gh`, `ripgrep` und `less` bringt das Basisimage bereits mit — nachgeprüft
# mit `docker run --rm solobox/base:latest bash -lc 'command -v gh rg less'`.
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    gnupg \
    curl \
    git \
    jq \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# --- uv ----------------------------------------------------------------------
# Der Python-Teil weiter unten arbeitet mit uv. Die claude-code-Basis-Images
# bringen es meistens mit — garantiert ist das aber nicht, also installieren wir
# es defensiv: nichts tun, wenn es schon da ist, sonst von astral.sh holen (der
# Host steht in der Netz-Erlaubnisliste des Wrappers).
# Ziel ist /usr/local/bin, damit uv sowohl für root (dieser Bau) als auch für
# den späteren Laufzeit-Benutzer `agent` auf dem PATH liegt.
RUN command -v uv >/dev/null 2>&1 || ( \
      export UV_INSTALL_DIR=/usr/local/bin \
      && curl -LsSf https://astral.sh/uv/install.sh | sh \
    )

# --- Node.js 24 --------------------------------------------------------------
# Das Basis-Image bringt eine Node-Laufzeit für Claude Code mit. Projekte hier
# zielen aber auf Node 24, also installieren wir es aus dem NodeSource-Repo —
# danach zeigen `node`, `npm` und `corepack` alle auf 24.
#
# Wichtig zum Verständnis: Was hier beim BAUEN aus dem Netz geholt wird,
# unterliegt NICHT der sbx-Netzregel. Die gilt für die laufende Sandbox. Beim
# Bauen redet der Docker-Daemon, nicht der Container.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- pnpm --------------------------------------------------------------------
# Node-Projekte hier verlangen pnpm >= 10 (`engines` in der package.json) und
# erzwingen es per `preinstall: npx only-allow pnpm`.
#
# ⚠️  Bewusst NICHT über corepack. `corepack prepare pnpm@10.11.0 --activate`
#     sieht sauberer aus, legt seine Aktivierung aber im Cache des BAU-Users
#     (root) ab, unter /root/.cache/node/corepack. Der Laufzeit-Benutzer `agent`
#     kommt dort nicht heran — und lädt sich beim ersten `pnpm`-Aufruf still
#     eine ganz andere Version nach:
#
#       $ pnpm --version
#       ! Corepack is about to download .../pnpm-11.21.0.tgz
#       11.21.0
#
#     Das ist keine Theorie: genau diese Ausgabe kam aus der ersten Fassung
#     dieses Images. `npm install -g` landet dagegen in
#     /usr/local/lib/node_modules und gilt für alle Benutzer fest.
#
# Andere pnpm-Version gewünscht? Genau diese eine Zeile ändern und neu bauen.
RUN npm install -g pnpm@10.11.0

# --- Lieferketten-Schutz: Aikido Safe Chain ----------------------------------
# safe-chain schiebt sich vor die Paketmanager (npm/npx/pnpm/pnpx/uv/uvx) und
# prüft Pakete VOR der Installation auf Schadcode.
#
# Wir installieren es global und schreiben die Shell-Funktionen selbst nach
# /etc/sandbox-persistent.sh, statt `safe-chain setup` laufen zu lassen. Grund:
# diese Datei wird vor jedem bash-Aufruf in der Sandbox eingelesen, gilt damit
# auch für den Laufzeit-Benutzer `agent` — und sie steckt im Image, überlebt
# also ein `sbx rm` samt Neuanlegen.
#
# Die Funktionen greifen NUR zur Laufzeit. Die RUN-Schritte oben laufen ohne
# sie, das Image baut also ohne Zwischenschicht. Fehlt der aikido-Shim einmal,
# fällt jede Funktion mit einer Warnung auf das echte Werkzeug zurück, statt
# den Befehl scheitern zu lassen. Die Prüfungen erreichen *.aikido.dev — der
# Host steht in der Erlaubnisliste des Wrappers.
RUN npm install -g @aikidosec/safe-chain

RUN cat >> /etc/sandbox-persistent.sh <<'EOF'

# Aikido Safe Chain — Paketmanager abfangen und vor der Installation prüfen.
npm()  { if command -v aikido-npm  >/dev/null 2>&1; then aikido-npm  "$@"; else echo "Warnung: safe-chain fehlt; npm ungeschuetzt."  >&2; command npm  "$@"; fi; }
npx()  { if command -v aikido-npx  >/dev/null 2>&1; then aikido-npx  "$@"; else echo "Warnung: safe-chain fehlt; npx ungeschuetzt."  >&2; command npx  "$@"; fi; }
pnpm() { if command -v aikido-pnpm >/dev/null 2>&1; then aikido-pnpm "$@"; else echo "Warnung: safe-chain fehlt; pnpm ungeschuetzt." >&2; command pnpm "$@"; fi; }
pnpx() { if command -v aikido-pnpx >/dev/null 2>&1; then aikido-pnpx "$@"; else echo "Warnung: safe-chain fehlt; pnpx ungeschuetzt." >&2; command pnpx "$@"; fi; }
uv()   { if command -v aikido-uv   >/dev/null 2>&1; then aikido-uv   "$@"; else echo "Warnung: safe-chain fehlt; uv ungeschuetzt."   >&2; command uv   "$@"; fi; }
uvx()  { if command -v aikido-uvx  >/dev/null 2>&1; then aikido-uvx  "$@"; else echo "Warnung: safe-chain fehlt; uvx ungeschuetzt."  >&2; command uvx  "$@"; fi; }
EOF

# --- Playwright mit Chromium -------------------------------------------------
# Chromium landet im gemeinsamen, für alle lesbaren Cache /ms-playwright, damit
# der Laufzeit-Benutzer `agent` es benutzen kann, ohne es erneut zu laden.
#
# @playwright/test kommt bewusst als @latest und nicht auf eine Version gepinnt:
# ältere Versionen kennen die Ubuntu-Ausgabe des Basis-Images teilweise nicht.
#
# `install-deps` darf scheitern (|| true): für die Ubuntu-Ausgabe des
# Basis-Images gibt es nicht immer eine gepflegte Playwright-Paketliste. Der
# Browser läuft in der Praxis trotzdem, weil die nötigen Bibliotheken schon im
# Basis-Image stecken. Falls doch ein Startfehler auftritt, gehört die fehlende
# Bibliothek in den apt-Block ganz oben.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g @playwright/test@latest \
    && playwright install-deps chromium || true \
    && playwright install chromium \
    && chmod -R a+rX /ms-playwright

# --- Playwright-MCP vorwärmen ------------------------------------------------
# Das Paket wandert nur in den globalen npm-Cache, damit ein späteres
# `npx @playwright/mcp@latest` sofort startet statt erst zu laden. Registriert
# wird der Server hier NICHT: MCP-Server kommen in solobox entweder über deine
# Plugins oder über `sbx mcp add`/`sbx mcp load` (Kapitel 4).
RUN npm install -g @playwright/mcp@latest

# --- Python: 3.10, 3.12 und 3.14 ---------------------------------------------
# Eine Sandbox für alle Projekte heißt: mehrere Python-Versionen gleichzeitig.
# uv legt sie in ein gemeinsames, für alle lesbares Verzeichnis; über die
# ENV-Variable findet auch der Laufzeit-Benutzer `agent` sie wieder — und wählt
# automatisch die passende, wenn ein Projekt eine .python-version mitbringt.
#
# Absichtlich nur Minor-Versionen, keine Patchlevel: im Kursmaterial ist eine
# lesbare, immer aktuelle Zeile mehr wert als ein bitgleicher Nachbau. Ob sich
# etwas geändert hat, erkennt der Wrapper ohnehin am Text dieses Dockerfiles.
#
# Hinweis zu 3.14: die Version ist jung. Für manche Pakete gibt es noch keine
# fertigen Wheels, dann wird aus dem Quellcode gebaut — das braucht Zeit und
# einen Compiler. Wer darauf stößt, weiß jetzt warum.
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN mkdir -p "$UV_PYTHON_INSTALL_DIR" \
    && uv python install 3.10 3.12 3.14 \
    && chmod -R a+rX "$UV_PYTHON_INSTALL_DIR"

# Jede Version einzeln aufrufbar machen, und 3.12 zum Standard erklären.
# /usr/local/bin steht auf dem PATH vor /usr/bin, diese Links gewinnen also
# gegen das System-Python — /usr/bin/python3 bleibt für apt & Co. unangetastet.
RUN ln -sf "$(uv python find 3.10)" /usr/local/bin/python3.10 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3.12 \
    && ln -sf "$(uv python find 3.14)" /usr/local/bin/python3.14 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python3 \
    && ln -sf "$(uv python find 3.12)" /usr/local/bin/python

# --- Dauerhafte Umgebung -----------------------------------------------------
# Alles, was an /etc/sandbox-persistent.sh angehängt wird, liest die Sandbox vor
# jedem bash-Aufruf ein. Weil es im Image steckt, überlebt es das Entfernen und
# Neuanlegen der Sandbox. Immer anhängen (>>), nie überschreiben — und keine
# Shell-Completion-Skripte hier hineinschreiben.
RUN echo 'export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright' >> /etc/sandbox-persistent.sh \
    && echo 'export PNPM_HOME="$HOME/.local/share/pnpm"' >> /etc/sandbox-persistent.sh \
    && echo 'export PATH="$PNPM_HOME:$PATH"' >> /etc/sandbox-persistent.sh \
    && echo 'export UV_PYTHON_INSTALL_DIR=/opt/uv-python' >> /etc/sandbox-persistent.sh

# --- Optional: gcloud CLI ----------------------------------------------------
# Bewusst NICHT eingebaut — es macht das Image spürbar größer, und die meisten
# Projekte brauchen es nicht. Wer es braucht, entfernt die Kommentarzeichen und
# baut neu (`solobox update`):
#
# RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
#     | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
# RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
#     | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
# RUN apt-get update && apt-get install -y google-cloud-cli \
#     && rm -rf /var/lib/apt/lists/*
# RUN echo 'export CLOUDSDK_CORE_DISABLE_PROMPTS=1' >> /etc/sandbox-persistent.sh
#
# Dazu gehören zwei Hosts in die Netz-Erlaubnisliste (EXTRA_HOSTS in der Conf):
#   packages.cloud.google.com   und   *.googleapis.com

USER agent
