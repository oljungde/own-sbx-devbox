# Kapitel 2 — Ein eigenes Dockerfile

**Ziel:** Eine Bauanleitung für unser eigenes Sandbox-Image schreiben, mit allen
Werkzeugen, die in Kapitel 1 gefehlt haben.

**Am Ende dieses Kapitels:** Du hast ein Dockerfile. Gebaut wird es in Kapitel 3.

---

## Drei Begriffe, die man leicht verwechselt

```bash
Dockerfile  --docker build-->  Image  --sbx template load-->  Template
                                                                 |
                                                        sbx create -t
                                                                 v
                                                              Sandbox
```

| Begriff        | Was es ist                                                |
| -------------- | --------------------------------------------------------- |
| **Dockerfile** | Die Bauanleitung. Eine Textdatei.                         |
| **Image**      | Das gebaute Ergebnis. Mehrere GB, liegt in deinem Docker. |
| **Template**   | Dasselbe Image, aber im Store von `sbx` registriert.      |
| **Sandbox**    | Der laufende Container, erzeugt aus einem Template.       |

Das **Template wird einmal pro Rechner gebaut**. Daraus entstehen beliebig viele
Sandboxes — für dein privates Zeug, für den Kurs, für ein Experiment.

## Das Repo anlegen

```bash
mkdir -p ~/dev/own/devbox/v1
cd ~/dev/own/devbox
git init
```

Der Unterordner heißt `v1/` — hier wohnt Variante 1. Die beiden anderen
Varianten liegen später daneben in `v2/` und `v3/`, und keine von ihnen heißt
`sbx/`. Das ist Absicht: Falls auf deinem Rechner noch ein anderes
Sandbox-Setup läuft, erkennen manche Wrapper einen Ordner namens `sbx/`
automatisch und schalten in einen Sondermodus. Ein eigener Name erspart dir
stundenlange Fehlersuche.

## Die Basis

```dockerfile
FROM docker/sandbox-templates:claude-code-docker

USER root
```

Docker liefert fertige Sandbox-Images für die gängigen Agenten. Wir bauen auf dem
Claude-Code-Image auf und ergänzen es. `USER root`, weil Installieren
Root-Rechte braucht — ganz am Ende schalten wir zurück.

## Grundausstattung

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git build-essential jq ripgrep less \
    && rm -rf /var/lib/apt/lists/*
```

Drei davon verdienen eine Erklärung:

**`build-essential`** ist das wichtigste Paket in dieser Zeile. Es bringt `gcc`,
`g++`, `make` und die C-Header. Gebraucht wird es, sobald ein Paket **nativen
Code kompilieren** muss:

```bash
pip install irgendwas
  → error: command 'gcc' failed: No such file or directory
```

Das trifft dich garantiert bei **Python 3.14**: Die Version ist so neu, dass
viele Pakete noch kein fertiges Wheel dafür anbieten und aus dem Quellcode
gebaut werden müssen. Ohne `build-essential` wäre 3.14 in der Sandbox praktisch
unbenutzbar.

**`jq`** filtert JSON auf der Kommandozeile. Fast alles moderne Tooling antwortet
in JSON — ohne `jq` müsste der Agent das mit `grep` zerlegen, was regelmäßig
schiefgeht.

```bash
gh api repos/foo/bar/pulls | jq '.[].title'
```

**`ripgrep`** (`rg`) sucht rekursiv durch ein Projekt, respektiert `.gitignore`
und überspringt `node_modules`. Sekunden werden zu Millisekunden.

## Die Werkzeuge

Der Rest des Dockerfiles folgt immer demselben Muster: installieren, an einen
Ort legen, den auch der Laufzeit-User lesen kann, fertig. Die vollständige Datei
mit allen Kommentaren liegt unter [`v1/Dockerfile`](../../v1/Dockerfile)
— **lies sie einmal von oben nach unten durch.** Sie ist absichtlich so
kommentiert, dass sie sich wie ein Text liest.

Hier nur die Punkte, an denen Leute typischerweise stolpern:

### Drei Python-Versionen nebeneinander

```dockerfile
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN mkdir -p "$UV_PYTHON_INSTALL_DIR" \
    && uv python install 3.10 3.12 3.14 \
    && chmod -R a+rX "$UV_PYTHON_INSTALL_DIR" \
    && PYBIN="$(uv python find 3.12)" \
    && ln -sf "$PYBIN" /usr/local/bin/python3 \
    && ln -sf "$PYBIN" /usr/local/bin/python
```

Zwei Dinge passieren hier:

1. `uv` installiert drei Interpreter in ein **gemeinsames, world-readable**
   Verzeichnis. Das `chmod -R a+rX` ist kein Detail: gebaut wird als `root`,
   benutzt wird als `agent` — ohne Leserecht wären die Interpreter unbrauchbar.
2. Die Symlinks legen fest, was ein blankes `python` ergibt: **3.12**.

Für einzelne Projekte musst du nichts tun. Legst du eine `.python-version` an,
wählt `uv` automatisch die passende:

```bash
echo "3.10" > .python-version
uv run python --version    # Python 3.10.x
```

### `chmod a+rX` — warum großes X?

Kleines `x` würde _jede_ Datei ausführbar machen, auch Textdateien. Großes `X`
setzt das Ausführrecht **nur bei Verzeichnissen und Dateien, die schon für
irgendjemanden ausführbar sind**. Genau das will man hier.

### Die PATH-Reihenfolge

`/usr/local/bin` steht vor `/usr/bin`. Deshalb gewinnt unser Python 3.12 für
Shell und Agent — während `/usr/bin/python3` für die System-Werkzeuge
unangetastet bleibt. Kaputte Systempakete durch einen überschriebenen
Python sind ein klassischer Container-Fehler.

## Zum Schluss

```dockerfile
USER agent
```

Ab hier läuft alles unprivilegiert. Vergisst du diese Zeile, arbeitet der Agent
als `root` — und das untergräbt einen Teil dessen, wofür die Sandbox da ist.

---

Lege jetzt die Datei `v1/Dockerfile` an. Nimm den Inhalt aus
[`v1/Dockerfile`](../../v1/Dockerfile) dieses Repos — sie ist
durchkommentiert und genau der Stand, den Kapitel 3 baut.

➡️ **Weiter mit [Kapitel 3 — Bauen und laden](03-bauen-und-laden.md)**
