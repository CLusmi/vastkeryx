#!/usr/bin/env bash
# Utilise pendant la construction de l'image (etape "fetch" du Dockerfile).
# Telecharge l'archive Linux officielle de keryx-miner, verifie son empreinte
# SHA-256, puis installe tout son contenu dans /opt/miners/keryx/.
#
# Les fichiers de l'archive doivent rester ensemble : keryx-miner charge le
# plugin de minage (libkeryxcuda.so), le moteur d'inference (libkeryx-llama.so)
# et les librairies CUDA places a cote de lui.
#
# Usage : fetch-miner.sh <version> <url> <sha256>
set -euo pipefail

version="${1:?version manquante}"
url="${2:?URL manquante (build-arg vide ?)}"
sha256="${3:?empreinte SHA-256 manquante}"
dest=/opt/miners/keryx

if [[ "$url" != https://github.com/Keryx-Labs/keryx-miner/releases/download/* ]]; then
  echo "ERREUR: l'archive doit venir d'une release GitHub Keryx-Labs/keryx-miner : $url" >&2
  exit 1
fi
if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERREUR: empreinte SHA-256 invalide : $sha256" >&2
  exit 1
fi

work=/tmp/fetch-keryx
mkdir -p "$work/extract"
archive="$work/$(basename "$url")"

echo ">> keryx-miner $version : $url"
curl -fsSL --retry 3 -o "$archive" "$url"

echo "${sha256}  ${archive}" | sha256sum -c -

unzip -q "$archive" -d "$work/extract"

# L'archive peut etre a plat ou dans un dossier : on part du binaire.
found=$(find "$work/extract" -type f -name keryx-miner)
if [[ $(printf '%s\n' "$found" | grep -c .) -ne 1 ]]; then
  echo "ERREUR: binaire 'keryx-miner' introuvable (ou en double) dans l'archive." >&2
  exit 1
fi
src=$(dirname "$found")
for lib in libkeryxcuda.so libkeryx-llama.so; do
  if [[ ! -f "$src/$lib" ]]; then
    echo "ERREUR: '$lib' absent de l'archive, a cote de keryx-miner." >&2
    exit 1
  fi
done

mkdir -p "$dest"
cp -a "$src"/. "$dest"/
chown -R root:root "$dest"
chmod 0755 "$dest/keryx-miner"
echo "keryx=${version}" >> /opt/miners/VERSIONS
echo ">> installe dans $dest :"
ls -l "$dest"
rm -rf "$work"
