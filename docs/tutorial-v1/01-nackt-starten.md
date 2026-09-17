# Kapitel 1 — Nackt starten

**Ziel:** Eine Sandbox starten, in der Claude läuft — ganz ohne Vorbereitung.
Und dabei erleben, was alles _fehlt_. Genau diese Lücken füllen wir in den
folgenden Kapiteln.

**Am Ende dieses Kapitels:** Du hast eine laufende Sandbox und verstehst, warum
sie so wenig kann.

---

## Was ist eine Sandbox überhaupt?

Stell dir Claude als einen Helfer vor, dem du dein Projekt gibst. Ohne Sandbox
läuft er auf deinem Rechner mit _deinen_ Rechten: Er sieht dein ganzes
Home-Verzeichnis, deine SSH-Schlüssel, deine Zugangsdaten für alles.

Eine Sandbox ist ein abgeschlossener Container. Der Helfer sitzt darin und sieht
nur das, was du bewusst hineinreichst. Docker Sandboxes (`sbx`) ist das Werkzeug,
das diesen Container baut und den Agenten darin startet.

## Voraussetzungen

```bash
sbx version      # sollte v0.38 oder neuer zeigen
docker --version
```

Fehlt `sbx`, findest du die Installationsanleitung unter
<https://docs.docker.com/ai/sandboxes/get-started/>.

## Schritt 1: Ein Übungsprojekt

Wir wollen etwas haben, das die Sandbox sehen kann:

```bash
mkdir -p ~/dev/lernen/hallo-sandbox
cd ~/dev/lernen/hallo-sandbox
git init
echo 'print("Hallo aus der Sandbox")' > hallo.py
```

## Schritt 2: Starten

```bash
sbx run claude .
```

Beim allerersten Mal fragt `sbx` nach einer **Netzwerk-Policy**:

```bash
  1. Open         — Aller Netzwerkverkehr erlaubt.
❯ 2. Balanced     — Standardmäßig blockiert, gängige Dev-Seiten erlaubt.
  3. Locked Down  — Alles blockiert, außer du erlaubst es ausdrücklich.
```

Wähle **Balanced**. Diese Entscheidung gilt einmalig für die ganze Maschine und
ist später änderbar.

Der Punkt am Ende (`.`) ist der Ordner, den die Sandbox sehen darf — dein
aktuelles Verzeichnis.

## Schritt 3: Anmelden

Claude startet und will einen Login. Das ist **kein Fehler**, sondern der
wichtigste Lerneffekt dieses Kapitels.

Aus der Docker-Dokumentation:

> Sandboxes do not inherit user-level configuration from the host machine, such
> as `~/.claude`. Only project-level configuration files located within the
> working directory are accessible inside the sandbox.

Übersetzt: **Die Sandbox erbt nichts aus deinem Home-Verzeichnis.** Nicht deine
Anmeldung, nicht deine Skills, nicht deine Agents. Das ist Absicht — in
`~/.claude` liegt unter anderem deine `.credentials.json`, und die hat in einem
Container nichts verloren.

Melde dich also in der Sandbox an:

```bash
claude auth login --claudeai
```

> 💡 Diese Anmeldung überlebt Stoppen und Neustarten der Sandbox — aber **nicht**
> das Entfernen mit `sbx rm`. Danach musst du dich neu anmelden.

## Schritt 4: Die Lücken erkunden

Öffne eine Shell in der Sandbox (in einem zweiten Terminal):

```bash
sbx ls                      # zeigt den Namen deiner Sandbox
sbx exec -it <name> bash
```

Und probier aus, was fehlt:

```bash
python --version     # Python 3.x — aber welche? Und nur eine.
poetry --version     # command not found
ruff --version       # command not found
pnpm --version       # command not found
gh --version         # vielleicht da, vielleicht nicht
```

Und jetzt das Netzwerk:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com
curl -sS -o /dev/null -w '%{http_code}\n' https://example.com
```

Der zweite Aufruf schlägt fehl. Die Sandbox darf nur bestimmte Hosts erreichen —
das ist die Netzwerk-Policy aus Schritt 2 bei der Arbeit.

## Was du jetzt weißt

| Erkenntnis                              | Bedeutung fürs nächste Kapitel    |
| --------------------------------------- | --------------------------------- |
| Die Sandbox erbt nichts aus `~/.claude` | Kapitel 6 holt das gezielt zurück |
| Die Toolchain ist minimal               | Kapitel 2 baut ein eigenes Image  |
| Das Netz ist standardmäßig zu           | Kapitel 4 öffnet es kontrolliert  |
| Nur ein Ordner ist sichtbar             | Kapitel 5 mountet mehrere         |

## Aufräumen

Die Sandbox darf ruhig stehen bleiben — sie kostet nichts, solange sie gestoppt
ist. Wenn du sie loswerden willst:

```bash
sbx ls                  # Namen ablesen
sbx rm <name>
```

---

➡️ **Weiter mit [Kapitel 2 — Ein eigenes Dockerfile](02-eigenes-dockerfile.md)**
