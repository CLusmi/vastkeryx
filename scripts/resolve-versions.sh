#!/usr/bin/env bash
# Trouve la version de keryx-miner a mettre dans l'image et affiche les
# build-args du Dockerfile (une ligne CLE=VALEUR).
#
# Sans argument : derniere release stable de github.com/Keryx-Labs/keryx-miner.
# Avec une etiquette (ex. v0.5.7-PoM) : cette release-la.
#
# Pour l'archive Linux : URL + empreinte SHA-256 calculee par GitHub au moment
# ou l'auteur a publie le fichier (champ "digest" de l'API). Le Dockerfile
# refuse toute archive dont l'empreinte ne correspond pas.
#
# Necessite : gh (CLI GitHub, authentifie via GH_TOKEN) et jq.
set -euo pipefail

repo="Keryx-Labs/keryx-miner"
pattern='^keryx-miner-.*-linux-amd64\.zip$'
wanted="${1:-}"

if [[ -n "$wanted" ]]; then
  json=$(gh api "repos/${repo}/releases/tags/${wanted}")
else
  # /releases/latest ignore les pre-releases et les brouillons.
  json=$(gh api "repos/${repo}/releases/latest")
fi

tag=$(jq -r '.tag_name' <<< "$json")
matches=$(jq -c --arg re "$pattern" '[.assets[] | select(.name | test($re))]' <<< "$json")
count=$(jq 'length' <<< "$matches")
if [[ "$count" -ne 1 ]]; then
  echo "ERREUR: ${repo} ${tag} : ${count} archive(s) Linux trouvee(s) au lieu d'une seule." >&2
  jq -r '.assets[].name' <<< "$json" >&2
  exit 1
fi

url=$(jq -r '.[0].browser_download_url' <<< "$matches")
digest=$(jq -r '.[0].digest // empty' <<< "$matches")

if [[ "$url" != "https://github.com/${repo}/releases/download/"* ]]; then
  echo "ERREUR: ${repo} : URL inattendue : ${url}" >&2
  exit 1
fi
if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "ERREUR: ${repo} ${tag} : pas d'empreinte SHA-256 publiee par GitHub pour $(basename "$url")." >&2
  exit 1
fi

echo "KERYX_VERSION=${tag}"
echo "KERYX_URL=${url}"
echo "KERYX_SHA256=${digest#sha256:}"
