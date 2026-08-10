# Kapitel 5 — Mehrere Projekte in einer Sandbox

**Ziel:** Weg von „eine Sandbox pro Projekt". Eine Sandbox, die alle deine
Projekte sieht.

**Am Ende dieses Kapitels:** Eine Sandbox, in der neue Projekte automatisch
auftauchen, ohne dass du irgendetwas neu bauen musst.

---

## Das Problem

Legt man für jedes Repo eine eigene Sandbox an, hat man nach einem halben Jahr
zwanzig Stück. Jede mit eigenem Login, eigenem Zustand, eigenen installierten
Paketen. Und jedes Mal, wenn du an einem neuen Projekt anfängst, geht die
Einrichtung von vorne los.

## Die Lösung: mehrere Workspaces

`sbx` kann mehrere Ordner gleichzeitig einhängen:

```bash
sbx create -t devbox/base:latest --name devbox-privat claude \
  ~/dev/own \
  ~/dev/referenz:ro
```

Zwei Regeln dazu:

- Der **erste** Pfad ist der Startordner (_Primary Workspace_). Dort landet der
  Agent beim Start.
- Alle **weiteren** werden unter ihrem _absoluten Host-Pfad_ eingehängt. Ein
  `~/dev/referenz` auf dem Host ist in der Sandbox unter genau demselben Pfad
  erreichbar.

Das `:ro` am Ende macht einen Ordner **schreibgeschützt**. Ideal für
Referenzmaterial, das der Agent lesen, aber nicht anfassen soll.

## ⚠️ Die eine Regel, die du dir merken musst

> **Workspaces lassen sich nur beim Anlegen der Sandbox setzen.**

Versuchst du, einer bestehenden Sandbox einen Ordner nachzureichen, lehnt `sbx`
das ab. Der einzige Weg wäre `sbx rm` und komplett neu anlegen — und damit sind
Login, installierte Pakete und aller Zustand weg.

Daraus folgt die wichtigste Entscheidung dieses Kapitels:

> 🎯 **Mounte einen Dach-Ordner, nicht einzelne Projekte.**

Also nicht:

```bash
# schlecht — jedes neue Projekt kostet einen Neuaufbau
sbx create ... claude ~/dev/own/projekt-a ~/dev/own/projekt-b ~/dev/own/projekt-c
```

Sondern:

```bash
# gut — alles darunter ist automatisch dabei, für immer
sbx create ... claude ~/dev/own
```

Legst du morgen `~/dev/own/projekt-d` an, ist es sofort in der Sandbox. Ohne
irgendetwas zu tun.

## Ausprobieren

```bash
sbx rm devbox-lernen 2>/dev/null || true

sbx create -t devbox/base:latest --name devbox-privat claude ~/dev/own
sbx exec -it devbox-privat bash
```

In der Sandbox:

```bash
pwd                 # dein Primary Workspace
ls ~/dev/own        # alle Projekte auf einmal
```

Und dann, auf dem Host, in einem anderen Terminal:

```bash
mkdir -p ~/dev/own/brandneu && echo "hallo" > ~/dev/own/brandneu/test.txt
```

Zurück in der Sandbox:

```bash
cat ~/dev/own/brandneu/test.txt     # ist sofort da
```

## Trennen, wenn es sich lohnt

Ein Dach-Ordner heißt nicht, dass alles in **eine** Sandbox muss. Getrennte
Sandboxes sind sinnvoll, wenn sich Dinge unterscheiden sollen:

| Grund                   | Beispiel                             |
| ----------------------- | ------------------------------------ |
| Andere Zugangsdaten     | privat vs. beruflich                 |
| Andere Netzregeln       | ein Projekt braucht eine interne API |
| Anderer Laufzeitzustand | globale npm-Pakete, die sich beißen  |

```bash
sbx create -t devbox/base:latest --name devbox-privat  claude ~/dev/own
sbx create -t devbox/base:latest --name devbox-lernen  claude ~/dev/lernen
```

Beide laufen aus **demselben Template**. Das Bauen ist einmalig, das Anlegen
kostet Sekunden. Und sie können gleichzeitig laufen.

## Was du dabei aufgibst

Ehrlichkeitshalber: Eine Sandbox mit einem Dach-Ordner sieht **alle** Projekte
darunter — auch während der Agent an einem einzigen arbeitet. Ist das ein
Problem, mounte gezielter oder benutze `:ro` für alles, was nur gelesen werden
soll.

---

➡️ **Weiter mit [Kapitel 6 — Globale und lokale Konfiguration](06-globale-und-lokale-config.md)**
