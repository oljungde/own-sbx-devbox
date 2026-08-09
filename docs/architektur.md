# Architektur — das Warum hinter den Entscheidungen

Das Tutorial erklärt, *wie* devbox gebaut wird. Dieses Dokument erklärt, *warum*
es so und nicht anders gebaut ist. Wenn du das Projekt umbauen willst, lies das
hier zuerst.

---

## Die drei Ebenen

```
Dockerfile  --docker build-->  Image  --sbx template load-->  Template
                                                                 |
                                                        sbx create -t
                                                                 v
                                                              Sandbox
```

Das **Template ist teuer** (Minuten, Gigabyte), die **Sandbox ist billig**
(Sekunden). Daraus folgt die Grundform: *ein* Template pro Rechner, *mehrere*
Sandboxes daraus.

Der Umweg über `docker save` existiert, weil der Docker-Daemon von `sbx` nicht
derselbe ist wie dein lokaler und dessen Image-Store nicht sieht.

---

## Wrapper statt Kit

`sbx` bietet ein deklaratives Kit-Format an. Es liest sich besser als Bash. Wir
benutzen es trotzdem nicht als Fundament:

```
$ sbx kit --help
EXPERIMENTAL: this command may change or be removed in future releases.
```

Für Material, das über Monate in einem Kurs benutzt wird, ist das ein
inakzeptables Risiko. Entscheidend war aber ein zweiter Befund: **Es gibt nichts,
was ein Kit kann und ein stabiles Kommando nicht.**

| Kit-Feature | Stabile Entsprechung |
|---|---|
| `permissions.network` | `sbx policy allow network --sandbox` |
| `credentials` | `sbx secret` |
| Umgebungsvariablen | `/etc/sandbox-persistent.sh` |
| Startup-Kommandos | `sbx exec -d` |

Ein Kit ist also Bequemlichkeit, kein Ermöglicher. Es liegt als
[`devbox/kit/kit.yaml`](../devbox/kit/kit.yaml) bei, damit man es kennenlernen
kann — aber nichts hängt davon ab.

**Dasselbe gilt für `sbx skills`** (ebenfalls EXPERIMENTAL). Siehe unten.

---

## Mounten statt kopieren

Skills und Agents, die man in *allen* Projekten braucht, in *jedes* Projekt zu
kopieren, erzeugt so viele Wahrheiten, wie es Projekte gibt. Nach kurzer Zeit
laufen sie auseinander.

Deshalb: read-only mounten, eine Quelle.

**Warum nicht `sbx skills import`?**

| | `sbx skills import` | `:ro`-Mount |
|---|---|---|
| Aktualität | Kopie, Re-Import nötig | live |
| Schreibrechte | Store ist **read-write** | read-only |
| Umfang | nur `skills` | skills, agents, commands, rules, plugins |
| Stabilität | EXPERIMENTAL | stabile Flags |

Die zweite Zeile ist die wichtigste — und beim Bauen dieses Repos nachgemessen:
Der Store ist beschreibbar und wird von **allen** Sandboxes der Maschine geteilt.
Eine Sandbox kann darüber die Konfiguration aller anderen verändern. Das
widerspricht dem Zweck einer Sandbox.

### Der Sonderfall `skills`

`sbx` hängt seinen Store an **genau den Pfad**, an den auch unser Symlink
gehört: `/home/agent/.claude/skills`. Sichtbar schon beim Anlegen:

```
skills  .../com.docker.sandboxes/sandboxes/agent-skills → /home/agent/.claude/skills
```

Ein `ln -sfn` dorthin **schlägt nicht fehl** — es meldet Erfolg und legt den Link
*in* das eingehängte Verzeichnis. Damit läge unsere Konfiguration in jeder
anderen Sandbox des Rechners. Ein stiller Seiteneffekt über Sandbox-Grenzen
hinweg, der ohne einen praktischen Test unentdeckt geblieben wäre.

Konsequenz im Wrapper: zwei getrennte Listen (`CLAUDE_SHARED` zum Mounten,
`CLAUDE_LINKED` zum Verlinken, ohne `skills`) plus eine Sicherung, die jedes Ziel
überspringt, das bereits ein echtes Verzeichnis ist.

Der Preis: Globale Skills sind in der Sandbox unter ihrem Host-Pfad **lesbar**,
werden aber nicht automatisch als User-Skills gefunden. Wer einen davon braucht,
legt ihn projektlokal unter `.claude/skills/` ab — womit er nebenbei versioniert
und im Team geteilt ist.

Ein `--no-share-skills`-Flag erwähnt zwar `sbx skills --help`, es existiert in
v0.38.0 aber weder bei `sbx create` noch bei `sbx run`.

**Warum `:ro` und nicht `~/.claude` komplett?**

- `.credentials.json` hat in einem Container nichts verloren.
- `settings.json` enthält Berechtigungen für den **Host**. Im Container passen
  sie nicht und können mehr erlauben, als beabsichtigt.
- Ohne `:ro` könnte ein Agent globale Skills verändern, die dann auf dem Host
  für **alle** Projekte gelten — ein Weg aus der Sandbox heraus.

**Warum Symlinks?** Extra-Workspaces werden unter ihrem absoluten *Host*-Pfad
eingehängt (`/Users/du/.claude/skills`), Claude sucht aber in
`/home/agent/.claude/skills`. Der Symlink verbindet beides.

---

## Dach-Ordner statt Einzelprojekte

Workspaces können **nur beim Anlegen** einer Sandbox gesetzt werden. Nachrüsten
bedeutet `sbx rm` — und damit Verlust von Login und Laufzeitzustand.

Ein Dach-Ordner (`~/dev/own`) statt einzelner Projekte macht diesen Fall
unmöglich: alles, was du künftig darunter anlegst, ist automatisch dabei.

Der Preis: Die Sandbox sieht alle Projekte darunter, auch während sie an einem
einzigen arbeitet. Wer das nicht will, mountet gezielter oder trennt in mehrere
Sandboxes.

---

## Netzregeln nur pro Sandbox

`sbx policy allow network <host>` wirkt **global** — auf alle Sandboxes des
Rechners, auch auf die anderer Setups. `--sandbox <name>` wirkt nur lokal.

devbox benutzt **ausschließlich** die sandbox-scoped Variante. Damit ist
garantiert, dass ein paralleles Sandbox-Setup auf derselben Maschine unberührt
bleibt.

Die Liste ist bewusst **kurz** (neun Einträge). Eine lange Union-Liste aller je
gebrauchten Hosts nimmt den Lerneffekt weg: Zu erleben, dass der Agent nicht
herauskommt, und zu wissen wie man das ändert, ist selbst Teil des Stoffs.

---

## Kollisionsschutz

devbox ist so benannt, dass es sich mit keinem anderen `sbx`-Setup überschneidet:

| | devbox | Typische Alternative |
|---|---|---|
| Ordner im Repo | `devbox/` | `sbx/` |
| Sandbox-Namen | `devbox-*` | `claude-*` |
| Template | `devbox/base` | agent-spezifisch |
| Zustand | `~/.local/state/devbox` | anderswo |

Der Ordnername ist kein Detail: Manche Wrapper erkennen ein Verzeichnis namens
`sbx/` im Git-Root **automatisch** und schalten daraufhin in einen Sondermodus
oder delegieren an ein dort liegendes Skript. Ein eigener Name verhindert, dass
zwei Systeme sich gegenseitig kapern.

---

## Safe Chain: eigene Shims

Statt den Installer seine Shims setzen zu lassen, erzeugt das Dockerfile sie
selbst — sechs Dateien mit je zehn Zeilen.

Drei Gründe:

1. **Sichtbarkeit.** Man kann `cat /opt/safe-chain/shims/npm` machen und in
   zehn Sekunden verstehen, was passiert.
2. **Schaltbarkeit.** Der Schutz hängt an genau einem PATH-Eintrag, also an
   einer `if`-Zeile in `/etc/sandbox-persistent.sh`. `DEVBOX_SAFE_CHAIN=0`
   schaltet ihn ab.
3. **Kein Selbstaufruf.** Jeder Shim entfernt sein eigenes Verzeichnis aus dem
   PATH, bevor er das echte Werkzeug ruft. Ohne das würde `aikido-npm` wieder
   unseren `npm`-Shim finden.

Der `else`-Zweig lässt `npm` mit einer Warnung durchlaufen, wenn Safe Chain
fehlt. Ein Schutz, der im Fehlerfall die Arbeit blockiert, wird umgangen — und
ein umgangener Schutz schützt nicht.

---

## pnpm nicht über corepack

`corepack prepare pnpm@X --activate` schreibt in den Cache des **Bau-Users**
(`root`). Zur Laufzeit läuft `agent`, sieht davon nichts und lädt beim ersten
Aufruf eine andere Version aus dem Netz.

Das ist beim Bauen dieses Images tatsächlich passiert und nachgemessen worden:
festgelegt war 10.11.0, im Container kam 11.21.0 an — mit Download zur Laufzeit.

`npm install -g pnpm@10.11.0` landet in `/usr/local/share/npm-global` und ist
für alle User sichtbar und fest.

---

## Was bewusst *nicht* gemacht wurde

| Nicht gemacht | Warum |
|---|---|
| Zentrales Image in einer Registry | Jeder soll sein eigenes Repo und Image besitzen und frei ändern können |
| Automatische Repo-Erkennung per Git-Remote | Erzeugt eine Sandbox pro Projekt — genau das, was wir loswerden wollten |
| Globale Netz-Policy | Würde parallele Setups mitverändern |
| `settings.json` mounten | Host-Berechtigungen gehören nicht in einen Container |
| `sbx kit` / `sbx skills` im kritischen Pfad | EXPERIMENTAL |
