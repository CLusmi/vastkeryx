#!/usr/bin/env bash
# Trouve la version de chaque mineur a mettre dans l'image et affiche les
# build-args du Dockerfile (une ligne CLE=VALEUR).
#
# keryx-miner : derniere release stable de github.com/Keryx-Labs/keryx-miner, ou
# l'etiquette donnee en argument (ex. v0.5.7-PoM).
# XMRig : derniere release stable de github.com/xmrig/xmrig.
#
# Pour chaque archive Linux : URL + empreinte SHA-256 calculee par GitHub au moment
# ou l'auteur a publie le fichier (champ "digest" de l'API). Le Dockerfile refuse
# toute archive dont l'empreinte ne correspond pas.
#
# Necessite : gh (CLI GitHub, authentifie via GH_TOKEN) et jq.
set -euo pipefail

# Affiche KEY_VERSION, KEY_URL et KEY_SHA256 pour une release.
# Usage : resolve CLE depot regex-de-l-archive [etiquette]
resolve() {
  local key="$1" repo="$2" pattern="$3" wanted="${4:-}" json tag matches count url digest
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

  echo "${key}_VERSION=${tag}"
  echo "${key}_URL=${url}"
  echo "${key}_SHA256=${digest#sha256:}"
}

resolve KERYX "Keryx-Labs/keryx-miner" '^keryx-miner-.*-linux-amd64\.zip$' "${1:-}"
resolve XMRIG "xmrig/xmrig" '^xmrig-[0-9.]+-linux-static-x64\.tar\.gz$'
