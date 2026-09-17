#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# check-links.sh — prüft, ob die relativen Links in der Doku ins Leere zeigen
#
# Warum überhaupt? Diese Doku besteht aus einem Dutzend Markdown-Dateien, die
# sich gegenseitig verlinken. Wird eine Datei umbenannt oder verschoben, merkt
# das niemand — der Link sieht im Editor völlig normal aus und fällt erst dem
# Lernenden auf, der darauf klickt.
#
# Bewusst ohne fremde GitHub-Action: Ein Repo, das Lieferketten-Sicherheit
# unterrichtet, sollte in seiner eigenen CI keine dritte Partei einbinden, die
# es nicht braucht. Und so ist das Skript auch lokal ausführbar:
#
#   ./scripts/check-links.sh
#
# Geprüft werden NUR relative Links auf Dateien im Repo. Externe URLs bleiben
# ungeprüft — dafür bräuchte die CI Netzzugang, und ein Fremdserver, der kurz
# nicht antwortet, würde unseren Bau rot färben.
# =============================================================================

# Vom Repo-Wurzelverzeichnis aus arbeiten, egal von wo aufgerufen.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fehler=0
geprueft=0

# -z / -d '' arbeitet mit NUL-Trennern statt Zeilenumbrüchen. Dateinamen mit
# Leerzeichen können uns damit nicht zerlegen.
while IFS= read -r -d '' datei; do
  verzeichnis="$(dirname "$datei")"

  # Aus "[Text](ziel)" das ziel herausziehen. Der Ausdruck nimmt bewusst kein
  # "!" davor mit — Bilder sind hier keine, aber die Regel würde auch für sie
  # gelten, wenn welche dazukommen.
  while IFS= read -r ziel; do
    # Leere Klammern, externe Links und reine Sprungmarken überspringen.
    case "$ziel" in
      ''|http://*|https://*|mailto:*|'#'*) continue ;;
    esac

    # Ein "#L65-L75" am Ende ist eine Zeilenmarke von GitHub, kein Dateiname.
    pfad="${ziel%%#*}"
    [ -n "$pfad" ] || continue

    geprueft=$((geprueft + 1))

    # Ein Link auf ein Verzeichnis ("docs/tutorial-v1/") ist gültig, wenn es das
    # Verzeichnis gibt — GitHub zeigt dann dessen Inhalt an.
    if [ ! -e "$verzeichnis/$pfad" ]; then
      printf '%s: Link zeigt ins Leere -> %s\n' "$datei" "$ziel" >&2
      fehler=$((fehler + 1))
    fi
  done < <(grep -o '](\([^)]*\))' "$datei" | sed 's/^](//; s/)$//' || true)
done < <(find . -name '*.md' -not -path './.git/*' -print0)

if [ "$fehler" -gt 0 ]; then
  printf '\n%s kaputte(r) Link(s) bei %s geprüften.\n' "$fehler" "$geprueft" >&2
  exit 1
fi

printf '%s relative Links geprüft, alle in Ordnung.\n' "$geprueft"
