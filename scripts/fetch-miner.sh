#!/usr/bin/env bash
# Utilise pendant la construction de l'image (etape "fetch" du Dockerfile).
# Telecharge l'archive Linux officielle d'un mineur, verifie son empreinte SHA-256,
# puis l'installe dans /opt/miners/<nom>/.
#
#   keryx : zip de github.com/Keryx-Labs/keryx-miner ; tout son contenu est installe,
#           les fichiers devant rester ensemble (keryx-miner charge le plugin de
#           minage libkeryxcuda.so, le moteur d'inference libkeryx-llama.so et les
#           librairies CUDA places a cote de lui).
#   xmrig : tar.gz (version statique) de github.com/xmrig/xmrig ; seul le binaire
#           xmrig est installe.
#
# Usage : fetch-miner.sh <keryx|xmrig> <version> <url> <sha256>
set -euo pipefail

name="${1:?nom manquant (keryx ou xmrig)}"
version="${2:?version manquante pour $name}"
url="${3:?URL manquante pour $name (build-arg vide ?)}"
sha256="${4:?empreinte SHA-256 manquante pour $name}"
dest="/opt/miners/$name"

case "$name" in
  keryx) repo="Keryx-Labs/keryx-miner" ;;
  xmrig) repo="xmrig/xmrig" ;;
  *) echo "ERREUR: mineur inconnu : $name (keryx ou xmrig)" >&2; exit 1 ;;
esac
if [[ "$url" != "https://github.com/${repo}/releases/download/"* ]]; then
  echo "ERREUR: $name : l'archive doit venir d'une release GitHub ${repo} : $url" >&2
  exit 1
fi
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERREUR: $name : empreinte SHA-256 invalide : $sha256" >&2
  exit 1
fi

work="/tmp/fetch-$name"
mkdir -p "$work/extract"
archive="$work/$(basename "$url")"

echo ">> $name $version : $url"
curl -fsSL --retry 3 -o "$archive" "$url"

echo "${sha256}  ${archive}" | sha256sum -c -

case "$name" in
  keryx)
    unzip -q "$archive" -d "$work/extract"
    # L'archive peut etre a plat ou dans un dossier : on part du binaire.
    found=$(find "$work/extract" -type f -name keryx-miner)
    if [[ $(printf '%s\n' "$found" | grep -c .) -ne 1 ]]; then
      echo "ERREUR: keryx : binaire 'keryx-miner' introuvable (ou en double) dans l'archive." >&2
      exit 1
    fi
    src=$(dirname "$found")
    for lib in libkeryxcuda.so libkeryx-llama.so; do
      if [[ ! -f "$src/$lib" ]]; then
        echo "ERREUR: keryx : '$lib' absent de l'archive, a cote de keryx-miner." >&2
        exit 1
      fi
    done
    mkdir -p "$dest"
    cp -a "$src"/. "$dest"/
    chown -R root:root "$dest"
    chmod 0755 "$dest/keryx-miner"
    ;;
  xmrig)
    tar -xzf "$archive" -C "$work/extract"
    found=$(find "$work/extract" -type f -name xmrig)
    if [[ $(printf '%s\n' "$found" | grep -c .) -ne 1 ]]; then
      echo "ERREUR: xmrig : binaire 'xmrig' introuvable (ou en double) dans l'archive." >&2
      exit 1
    fi
    install -D -m 0755 -o root -g root "$found" "$dest/xmrig"
    ;;
esac

echo "${name}=${version}" >> /opt/miners/VERSIONS
echo ">> installe dans $dest :"
ls -l "$dest"
rm -rf "$work"
