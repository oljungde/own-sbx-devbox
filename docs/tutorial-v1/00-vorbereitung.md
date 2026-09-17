# Kapitel 0 — Vorbereitung

**Ziel:** `sbx` und Docker auf deinem Rechner zum Laufen bringen — und vorher
wissen, ob dein Rechner überhaupt mitspielt.

**Am Ende dieses Kapitels:** `./v1/devbox.sh doctor` zeigt nur Häkchen.

> Wenn `sbx version` und `docker --version` bei dir schon antworten, überspring
> dieses Kapitel und fang mit [Kapitel 1](01-nackt-starten.md) an.

---

## Zuerst: Läuft das auf deinem Rechner?

Docker Sandboxes braucht Hardware-Virtualisierung, und das schränkt ein. Prüfe
das **bevor** du etwas installierst — sonst suchst du später an der falschen
Stelle.

|             | Unterstützt                                  | Nicht unterstützt                |
| ----------- | -------------------------------------------- | -------------------------------- |
| **macOS**   | macOS 14 (Sonoma) oder neuer, Apple Silicon  | Intel-Macs                       |
| **Windows** | Windows 11 auf x86_64 (Intel/AMD)            | Windows 10, Windows auf ARM      |
| **Linux**   | Ubuntu 24.04 oder neuer, x86_64 oder aarch64 | älteres Ubuntu, Systeme ohne KVM |

Dazu brauchst du **rund 8 GB freien Plattenplatz**: Das Image belegt etwa 5,9 GB,
und beim Übertragen in den `sbx`-Store entsteht kurzzeitig eine tar-Datei von
rund 1,4 GB.

Und einen Docker-Account — `sbx` verlangt eine Anmeldung, bevor es irgendetwas
tut.

## Die zwei Docker, die du brauchst

Hier stolpern die meisten, deshalb gleich am Anfang:

```bash
      ┌─ dein lokaler Docker ─┐        ┌─ die sbx-Laufzeit ────┐
      │  docker build         │  tar   │  sbx template load    │
      │  docker save          ├───────>│  sbx create / run     │
      └───────────────────────┘        └───────────────────────┘
```

Das sind **zwei getrennte Image-Speicher**. Der eine kennt die Images des anderen
nicht. Deshalb:

- Die `sbx`-Dokumentation sagt „Docker Desktop wird nicht benötigt" — das ist
  richtig, **für `sbx` allein**.
- devbox baut sein Image aber selbst, mit `docker build` auf dem Host. Dafür
  brauchst du **doch** einen lokalen Docker (Docker Desktop oder Docker Engine).

Kurz: `sbx` allein braucht keinen lokalen Docker, devbox braucht beides. Warum
der Umweg über eine tar-Datei nötig ist, steht in
[Kapitel 3](03-bauen-und-laden.md).

---

## Installation

### macOS

```bash
brew trust docker/tap
brew install docker/tap/sbx
sbx login
```

`sbx login` öffnet den Browser für die Docker-Anmeldung.

Lokalen Docker dazu, falls noch nicht vorhanden:

```bash
brew install --cask docker
```

Danach Docker Desktop einmal aus dem Programme-Ordner starten — der Daemon läuft
nicht von allein los.

### Linux (Ubuntu)

Erst prüfen, ob KVM da ist:

```bash
lsmod | grep kvm
```

Erwartet wird eine Zeile mit `kvm_intel`, `kvm_amd`, `kvm_arm64` oder `kvm`.
Kommt nichts, hilft `kvm-ok` bei der Diagnose — meist ist die Virtualisierung im
BIOS/UEFI abgeschaltet.

Dich selbst in die `kvm`-Gruppe aufnehmen:

```bash
sudo usermod -aG kvm "$USER"
newgrp kvm          # oder einmal ab- und wieder anmelden
```

Dann installieren:

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sbx login
```

> `REPO_ONLY=1` richtet nur die Paketquelle ein, ohne Docker gleich
> mitzuinstallieren. Den lokalen Docker brauchst du für devbox trotzdem —
> `sudo apt-get install docker-ce docker-ce-cli containerd.io`.

### Windows

Zwei Dinge sind hier anders als bei den anderen beiden.

**Erstens** braucht Windows die Hypervisor-Platform. In einer PowerShell **als
Administrator**:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
```

Danach neu starten. Dann:

```powershell
winget install -h Docker.sbx
sbx login
```

**Zweitens** ist `devbox.sh` ein Bash-Skript. PowerShell kann es nicht
ausführen. Du brauchst also eine Bash, und der empfohlene Weg ist **WSL2**:

```powershell
wsl --install -d Ubuntu
```

Docker Desktop dann mit aktiviertem WSL2-Backend installieren
(_Settings → Resources → WSL integration_), damit `docker` auch **innerhalb** der
WSL-Distribution antwortet.

> ⚠️ Lege das Repo **im WSL-Dateisystem** ab (`~/dev/own/devbox`), nicht unter
> `/mnt/c/...`. Über die Windows-Grenze ist Dateizugriff um Größenordnungen
> langsamer — bei einem Image von knapp 6 GB merkst du das deutlich.
>
> **Git Bash** funktioniert für einfache Fälle, ist aber nicht die getestete
> Umgebung: MSYS schreibt Pfade in die Form `/c/Users/...` um, was bei den
> Mount-Pfaden von `sbx create` zu Überraschungen führt.

---

## Prüfen

```bash
sbx version              # v0.38 oder neuer
docker --version         # der lokale Docker
docker run --rm hello-world
sbx diagnose             # sbx prüft sich selbst
```

`sbx diagnose` ist die erste Adresse, wenn `sbx` sich seltsam verhält — es
kennt die typischen Fehlkonfigurationen seiner eigenen Installation.

## Noch zwei Kleinigkeiten

**`gh` auf dem Host.** `./devbox.sh doctor` schaut danach, und im Sandbox-Image
ist es enthalten. Auf dem Host brauchst du es nicht zwingend, aber es ist
bequem:

```bash
brew install gh          # macOS
sudo apt-get install gh  # Ubuntu
gh auth login
```

**Das Repo holen.** Ab hier gehen alle Kapitel davon aus, dass du in deinem
eigenen Klon stehst:

```bash
git clone <deine-fork-url> ~/dev/own/devbox
cd ~/dev/own/devbox
```

---

## Geschafft

```bash
./v1/devbox.sh doctor
```

Erwartet werden Häkchen bei `sbx`, `docker` und `git`. Dass `~/.config/devbox/devbox.conf`
noch fehlt, ist an dieser Stelle richtig — die Datei legen wir in
[Kapitel 7](07-wrapper-und-kit.md) an.

Weiter mit [Kapitel 1 — Nackt starten](01-nackt-starten.md).

---

📖 Klemmt etwas: [troubleshooting.md](../troubleshooting.md). Offizielle
Installationsanleitung mit allen Sonderfällen:
<https://docs.docker.com/ai/sandboxes/get-started/>
