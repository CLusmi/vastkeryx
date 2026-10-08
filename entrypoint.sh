#!/usr/bin/env bash
# Lance keryx-miner sur les GPU NVIDIA. Les arguments de GPU_ARGS sont passes
# au mineur tels quels : l'image n'ajoute aucune option.
#
# Variables :
#   GPU_MINER         keryx (seule valeur possible)
#   GPU_ARGS          arguments de keryx-miner
#                     ex. --keryxd-address IP:PORT --mining-address keryx:ADRESSE --escrow-cert CERT
#   KERYX_ESCROW_KEY  facultatif : les 64 caracteres du fichier escrow.key, pour
#                     utiliser la meme cle escrow sur toutes les instances. Elle est
#                     ecrite dans escrow.key avant le lancement, jamais affichee.
#   RESTART_DELAY     secondes avant relance du mineur s'il s'arrete (defaut 10)
#   DRY_RUN=1         affiche les commandes finales sans rien lancer ni ecrire
#
# Au demarrage d'un conteneur neuf (aucun escrow_state.json), en mode noeud, la
# cle etant presente : keryx-miner --recover-escrow est lance une fois pour
# retrouver, via l'API Keryx, les gains en attente sur cette cle (y compris ceux
# laisses par des instances detruites). En cas d'echec, le minage demarre quand meme.
#
# Ensuite, le modele IA du palier choisi dans GPU_ARGS est telecharge depuis Hugging
# Face (bien plus rapide que la passerelle IPFS du mineur), s'il n'est pas deja la.
#
# Avec des arguments (docker run image --help), keryx-miner est lance
# directement avec ces arguments ; une commande (bash, nvidia-smi) est executee.
set -uo pipefail

MINERS_DIR=/opt/miners
keryx="$MINERS_DIR/keryx/keryx-miner"

log() { echo "[vastkeryx] $*"; }
die() { echo "[vastkeryx] ERREUR: $*" >&2; exit 1; }

# Mode direct : arguments passes au conteneur.
if [[ $# -gt 0 ]]; then
  if [[ "$1" != -* ]] && command -v "$1" >/dev/null 2>&1; then
    exec "$@"
  fi
  exec "$keryx" "$@"
fi

log "Version installee : $(tr '\n' ' ' < "$MINERS_DIR/VERSIONS")"

# Seuls les noms sont affiches, jamais les valeurs (la cle escrow est secrete).
present=()
absent=()
for name in GPU_MINER GPU_ARGS KERYX_ESCROW_KEY; do
  if [[ -n "${!name:-}" ]]; then present+=("$name"); else absent+=("$name"); fi
done
log "Variables recues : ${present[*]:-aucune}${absent[*]:+ ; absentes : ${absent[*]}}"

# --- Outils ----------------------------------------------------------------------

# Decoupe une chaine d'arguments en tableau, en respectant les guillemets
# ("valeur avec espace"). Resultat dans le tableau nomme par $2.
split_args() {
  local text="$1" target="$2" out
  local -a parsed=()
  # Guillemets autour de toute la valeur (l'interface de vast.ai peut les garder
  # quand la variable vient du champ Docker Options) : retires.
  if [[ "$text" =~ ^[[:space:]]*\"([^\"]*)\"[[:space:]]*$ || "$text" =~ ^[[:space:]]*\'([^\']*)\'[[:space:]]*$ ]]; then
    text="${BASH_REMATCH[1]}"
  fi
  if [[ -n "${text// /}" ]]; then
    out=$(printf '%s' "$text" | xargs printf '%s\n' 2>/dev/null) \
      || die "impossible de lire les arguments : guillemet non ferme ? ($text)"
    mapfile -t parsed <<< "$out"
  fi
  eval "$target=(\"\${parsed[@]}\")"
}

# Affiche une commande, en remettant des guillemets autour des valeurs qui en ont besoin.
show_cmd() {
  local out="" arg
  for arg in "$@"; do
    if [[ "$arg" == *[[:space:]\"\'\$]* || -z "$arg" ]]; then out+=" \"${arg//\"/\\\"}\""; else out+=" $arg"; fi
  done
  echo "${out# }"
}

# Vrai si l'option $1 figure deja dans les arguments ($2...), seule ou en --opt=valeur.
has_opt() {
  local opt="$1" arg
  shift
  for arg in "$@"; do
    [[ "$arg" == "$opt" || "$arg" == "$opt="* ]] && return 0
  done
  return 1
}

# Valeur qui suit l'une des options $1 (separees par |) dans les arguments ($2...), ou vide.
opt_value() {
  local opts="$1" prev="" arg o
  shift
  for arg in "$@"; do
    for o in ${opts//|/ }; do
      [[ "$prev" == "$o" ]] && { echo "$arg"; return; }
      [[ "$arg" == "$o="* ]] && { echo "${arg#*=}"; return; }
    done
    prev="$arg"
  done
}

# Chemin absolu (les chemins relatifs du mineur partent du dossier de travail).
abs_path() { if [[ "$1" == /* ]]; then echo "$1"; else echo "$PWD/$1"; fi; }

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# Vrai si $1 est une cle privee valide : 64 caracteres hexadecimaux, pas zero,
# inferieure a l'ordre de la courbe secp256k1 (meme controle que le mineur).
valid_privkey() {
  local key="$1" LC_ALL=C
  local order="fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] && [[ "$key" != "$(printf '%064d' 0)" ]] && [[ "$key" < "$order" ]]
}

# --- Verifications ---------------------------------------------------------------
if [[ -z "${GPU_MINER:-}" && -z "${GPU_ARGS:-}" ]]; then
  die "rien a miner : renseigne GPU_MINER=keryx et GPU_ARGS (arguments de keryx-miner)."
elif [[ -z "${GPU_ARGS:-}" ]]; then
  die "GPU_MINER est renseigne mais GPU_ARGS manque (ou vide)."
elif [[ -z "${GPU_MINER:-}" ]]; then
  die "GPU_ARGS est renseigne mais GPU_MINER manque (GPU_MINER=keryx)."
fi

case "$(lower "$GPU_MINER")" in
  keryx|keryx-miner) ;;
  *) die "GPU_MINER=${GPU_MINER} inconnu. Seule valeur possible : keryx." ;;
esac
[[ -x "$keryx" ]] || die "binaire introuvable : $keryx"

delay="${RESTART_DELAY:-10}"
[[ "$delay" =~ ^[0-9]+$ ]] || die "RESTART_DELAY=${delay} : nombre de secondes attendu."

split_args "$GPU_ARGS" gpu_user
[[ ${#gpu_user[@]} -gt 0 ]] || die "GPU_ARGS ne contient aucun argument."
if has_opt --recover-escrow "${gpu_user[@]}"; then
  die "retire --recover-escrow de GPU_ARGS : le mineur s'arreterait apres la recuperation. L'image la fait elle-meme au demarrage."
fi
gpu_cmd=("$keryx" "${gpu_user[@]}")

dry_run=0
[[ "${DRY_RUN:-0}" == 1 ]] && dry_run=1

# --- Escrow : cle commune et recuperation ---------------------------------------
# Memes chemins que le mineur : options de GPU_ARGS, sinon ses valeurs par defaut,
# relatives au dossier de travail.
key_opt=$(opt_value --escrow-key-file "${gpu_user[@]}")
key_file=$(abs_path "${key_opt:-escrow.key}")
state_opt=$(opt_value --escrow-state-file "${gpu_user[@]}")
state_file=$(abs_path "${state_opt:-escrow_state.json}")
state_base=$(basename "$state_file")
if [[ "$state_base" == *.* ]]; then
  journal_file="$(dirname "$state_file")/${state_base%.*}.journal"
else
  journal_file="${state_file}.journal"
fi
node=$(opt_value "--keryxd-address|-s" "${gpu_user[@]}")
pool_mode=0
[[ "$node" == stratum+tcp://* ]] && pool_mode=1

escrow_key=""
if [[ -n "${KERYX_ESCROW_KEY:-}" ]]; then
  escrow_key="${KERYX_ESCROW_KEY//[[:space:]\"\']/}"
  escrow_key=$(lower "$escrow_key")
  valid_privkey "$escrow_key" \
    || die "KERYX_ESCROW_KEY invalide (valeur non affichee) : il faut exactement le contenu du fichier escrow.key, 64 caracteres hexadecimaux (0-9, a-f)."
fi

# Ecrit la cle de KERYX_ESCROW_KEY dans le fichier de cle. Une autre cle deja
# presente (conteneur relance apres un changement de cle) n'est jamais effacee :
# elle est renommee avec son etat, car elle peut controler des gains.
install_escrow_key() {
  local current suffix f
  mkdir -p "$(dirname "$key_file")" || die "impossible de creer le dossier de $key_file"
  if [[ -e "$key_file" ]]; then
    current=$(tr -d '[:space:]' < "$key_file" | tr '[:upper:]' '[:lower:]')
    if [[ "$current" == "$escrow_key" ]]; then
      log "Escrow : cle deja en place dans $key_file (identique a KERYX_ESCROW_KEY)."
      return 0
    fi
    suffix="ancienne-$(date -u +%Y%m%d-%H%M%S)"
    for f in "$key_file" "$state_file" "$journal_file"; do
      if [[ -e "$f" ]]; then
        mv -- "$f" "$f.$suffix" || die "impossible de mettre de cote $f"
        log "Escrow : ATTENTION, $f contenait les donnees d'une autre cle : renomme en $f.$suffix (ne pas supprimer, cette cle peut controler des gains)."
      fi
    done
  fi
  (umask 077 && printf '%s\n' "$escrow_key" > "$key_file.tmp") || die "impossible d'ecrire $key_file"
  mv -f -- "$key_file.tmp" "$key_file" || die "impossible d'ecrire $key_file"
  chmod 600 "$key_file"
  log "Escrow : cle KERYX_ESCROW_KEY installee dans $key_file."
}

recover_cmd=("$keryx" "${gpu_user[@]}" --recover-escrow)

# Recupere une fois, via l'API Keryx, les gains en attente sur la cle (conteneur neuf).
recover_escrow() {
  local code
  if [[ $pool_mode -eq 1 ]]; then
    log "Escrow : mode pool (stratum), pas d'escrow : pas de recuperation."
    return 0
  fi
  if [[ ! -f "$key_file" ]]; then
    log "Escrow : pas de cle ($key_file) : pas de recuperation, keryx-miner va en creer une nouvelle."
    return 0
  fi
  if [[ -e "$state_file" ]]; then
    log "Escrow : etat deja present ($state_file) : pas de recuperation, keryx-miner reprend son suivi."
    return 0
  fi
  log "Escrow : recherche des gains en attente sur cette cle (keryx-miner --recover-escrow)..."
  # En tache de fond pour qu'un arret du conteneur pendant la recherche soit pris
  # en compte tout de suite (voir stop).
  phase=recover
  timeout 180 "${recover_cmd[@]}" &
  pid=$!
  wait "$pid"
  code=$?
  pid=0
  phase=""
  if [[ $code -eq 0 ]]; then
    log "Escrow : recuperation terminee."
  else
    log "Escrow : recuperation echouee (code $code) ; le minage demarre quand meme."
  fi
}

# --- Modele IA : telechargement depuis Hugging Face ------------------------------
# keryx-miner telecharge son modele depuis la passerelle IPFS de Keryx, souvent tres
# lente. Keryx-Labs publie les memes modeles sur Hugging Face, dans des zips sans
# compression : l'image telecharge directement la partie du zip qui contient
# model.gguf, a l'endroit ou le mineur le cherche, avec reprise en cas de coupure.
# Le mineur verifie ensuite l'empreinte du fichier (celle inscrite dans son code) ;
# si quelque chose echoue ici, il telecharge lui-meme comme avant.
# KERYX_MODELS_URL ne sert qu'aux tests de l'image.
models_url="${KERYX_MODELS_URL:-https://huggingface.co/datasets/Keryx-Labs/models/resolve/main}"

# Palier de keryx-miner -> modele(s) (nom du zip sur Hugging Face).
# high : tant qu'il ne connait pas la hauteur de la chaine, le mineur veut aussi le
# modele de l'ere suivante (Qwen3.8-27B a partir du hard fork H14).
declare -A tier_models=(
  [very-light]="Qwen3.5-9B-abliterated"
  [light]="GLM-4-9B-0414"
  [default]="Gemma-4-12B-abliterated"
  [high]="Qwen3.6-27B Qwen3.8-27B"
  [very-high]="Kimi-Linear-48B"
)

# Dossier des modeles : --models-dir, sinon KERYX_MODELS_DIR, sinon <dossier du mineur>/models.
models_opt=$(opt_value --models-dir "${gpu_user[@]}")
if [[ -n "$models_opt" ]]; then
  models_root=$(abs_path "$models_opt")
elif [[ -n "${KERYX_MODELS_DIR:-}" ]]; then
  models_root=$(abs_path "$KERYX_MODELS_DIR")
else
  models_root="$MINERS_DIR/keryx/models"
fi

# Palier demande dans GPU_ARGS (aucune option = default), plus ceux de --force-model.
base_tier=default
for t in very-light light high very-high; do
  has_opt "--$t" "${gpu_user[@]}" && base_tier=$t
done
wanted_tiers=("$base_tier")
forced=$(opt_value --force-model "${gpu_user[@]}")
if [[ -n "$forced" ]]; then
  IFS=',' read -r -a forced_list <<< "$forced"
  for t in "${forced_list[@]}"; do
    t=$(lower "${t//[[:space:]]/}")
    [[ -n "${tier_models[$t]:-}" ]] && wanted_tiers+=("$t")
  done
fi
wanted_models=()
for t in "${wanted_tiers[@]}"; do
  for m in ${tier_models[$t]}; do
    [[ " ${wanted_models[*]} " == *" $m "* ]] || wanted_models+=("$m")
  done
done

gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1e9 }'; }

# Entier non signe little-endian de $2 octets a la position $1 du fichier $zhdr.
le_u() { od -An -tu"$2" -j"$1" -N"$2" "$zhdr" | tr -d ' \n'; }

# Lit les en-tetes locaux au debut d'un zip ($1 : les premiers Ko du zip) jusqu'a
# l'entree */model.gguf. Resultat : zip_start (premier octet de model.gguf dans le
# zip), zip_size, zip_folder. Refuse tout ce qui n'est pas stocke sans compression.
parse_zip_head() {
  local zhdr="$1" off=0 hsize sig flags method csize usize nlen xlen name xoff xend p q id sz
  hsize=$(stat -c%s "$zhdr")
  while (( off + 30 <= hsize )); do
    sig=$(od -An -tx4 -j"$off" -N4 "$zhdr" | tr -d ' \n')
    [[ "$sig" == 04034b50 ]] || return 1
    flags=$(le_u $((off + 6)) 2)
    method=$(le_u $((off + 8)) 2)
    csize=$(le_u $((off + 18)) 4)
    usize=$(le_u $((off + 22)) 4)
    nlen=$(le_u $((off + 26)) 2)
    xlen=$(le_u $((off + 28)) 2)
    xoff=$((off + 30 + nlen))
    xend=$((xoff + xlen))
    (( xend <= hsize )) || return 1
    name=$(dd if="$zhdr" bs=1 skip=$((off + 30)) count="$nlen" 2>/dev/null)
    # Fichier de plus de 4 Go : vraies tailles dans le champ zip64 (id 1) des extras.
    if (( usize == 4294967295 || csize == 4294967295 )); then
      p=$xoff
      while (( p + 4 <= xend )); do
        id=$(le_u "$p" 2)
        sz=$(le_u $((p + 2)) 2)
        if (( id == 1 )); then
          q=$((p + 4))
          if (( usize == 4294967295 )); then usize=$(le_u "$q" 8); q=$((q + 8)); fi
          if (( csize == 4294967295 )); then csize=$(le_u "$q" 8); fi
          break
        fi
        p=$((p + 4 + sz))
      done
    fi
    (( (flags & 8) == 0 )) || return 1
    if [[ "$name" == */model.gguf ]]; then
      (( method == 0 && csize == usize && usize > 0 )) || return 1
      zip_start=$xend
      zip_size=$usize
      zip_folder="${name%/model.gguf}"
      return 0
    fi
    off=$((xend + csize))
  done
  return 1
}

# Nombre de connexions paralleles vers Hugging Face pour un modele : chacune
# telecharge sa part (segment) du fichier. Une seule connexion plafonne souvent a
# quelques Mo/s sur les machines louees.
dl_conns=8

# Octets deja ecrits dans le fichier $1 (fichier creux : seuls les blocs ecrits comptent).
allocated() {
  local b bs
  read -r b bs < <(stat -c '%b %B' "$1" 2>/dev/null || echo "0 0")
  echo $((b * bs))
}

# Une ligne de progression toutes les 30 s : $1 nom, $2 fichier, $3 taille finale.
progress_loop() {
  local name="$1" file="$2" total="$3" prev cur t0 t1
  prev=$(allocated "$file")
  t0=$(date +%s)
  while sleep 30; do
    cur=$(allocated "$file")
    (( cur > total )) && cur=$total
    t1=$(date +%s)
    awk -v n="$name" -v c="$cur" -v T="$total" -v p="$prev" -v dt=$((t1 - t0)) -v k="$dl_conns" 'BEGIN {
      if (dt < 1) dt = 1
      printf "[vastkeryx] Modele %s : %.1f / %.1f Go (%d %%), %.0f Mo/s (%d connexions)\n", n, c / 1e9, T / 1e9, 100 * c / T, (c - p) / 1e6 / dt, k }'
    prev=$cur
    t0=$t1
  done
}

# Telecharge le segment $1 de model.gguf dans le fichier partiel, a sa place.
# Avancement du segment : fichier <partiel>.seg<N> (octets ecrits et confirmes).
# Chaque essai dure au plus 60 s (l'avancement est enregistre a chaque fin d'essai :
# un arret du conteneur perd au plus une minute) ; moins de 100 Ko/s pendant 30 s :
# on coupe et on reprend. Pas d'abandon : en cas
# d'erreur, nouvel essai apres une pause qui grandit jusqu'a 60 s.
seg_worker() {
  local i="$1" s="${seg_s[$1]}" len="${seg_l[$1]}" st="$part.seg$1" errf done rem http got fails=0 wait_s
  local -a codes
  errf=$(mktemp)
  while :; do
    done=$(cat "$st" 2>/dev/null || echo 0)
    [[ "$done" =~ ^[0-9]+$ ]] || done=0
    (( done >= len )) && break
    rem=$((len - done))
    # --max-filesize : une reponse entiere (plage ignoree) est refusee avant d'ecrire ;
    # head -c : jamais plus que la taille du segment.
    curl -fsSL --connect-timeout 30 --max-time 60 --speed-limit 102400 --speed-time 30 \
         --max-filesize "$rem" -r "$((zip_start + s + done))-$((zip_start + s + len - 1))" \
         -w '%{stderr}\n%{http_code} %{size_download}\n' "$url" 2> "$errf" \
      | head -c "$rem" \
      | dd of="$part" bs=1M seek=$((s + done)) oflag=seek_bytes conv=notrunc status=none
    codes=("${PIPESTATUS[@]}")
    read -r http got < <(tail -n 1 "$errf")
    [[ "$got" =~ ^[0-9]+$ ]] || got=0
    (( got > rem )) && got=$rem
    if [[ "$http" == 206 && ${codes[2]} -eq 0 ]] && (( got > 0 )); then
      echo $((done + got)) > "$st.tmp" && mv -f "$st.tmp" "$st"
      fails=0
    else
      fails=$((fails + 1))
      wait_s=$((fails * 5))
      (( wait_s > 60 )) && wait_s=60
      if [[ ${codes[2]} -ne 0 ]]; then
        log "Modele $name : segment $((i + 1))/$dl_conns : ecriture impossible (disque plein ?) ; nouvel essai dans ${wait_s} s."
      else
        log "Modele $name : segment $((i + 1))/$dl_conns : erreur (curl code ${codes[0]}, HTTP ${http:-?}) ; nouvel essai dans ${wait_s} s."
      fi
      sleep "$wait_s"
    fi
  done
  rm -f "$errf"
}

# Telecharge le modele $1 (nom du zip) depuis Hugging Face, en $dl_conns connexions.
# Les segments sont ecrits a leur place dans model.gguf.partial, renomme en
# model.gguf une fois complet : keryx-miner ne voit jamais de fichier a moitie fait.
# Vrai si model.gguf est complet a la fin.
fetch_model() {
  local name="$1" url="$models_url/$1.zip" hdrf dir dest part layout want have prefix avail t0 have0 prog i s l c
  local -a wpids=()
  if [[ -f "$models_root/$name/.ok" && -f "$models_root/$name/model.gguf" ]]; then
    log "Modele $name : deja present et verifie par keryx-miner."
    return 0
  fi
  hdrf=$(mktemp)
  # --max-filesize : si le serveur ignorait la plage demandee, on ne telecharge pas tout.
  if ! curl -fsSL --retry 3 --connect-timeout 30 --max-time 120 --max-filesize 1048576 \
       -r 0-65535 -o "$hdrf" "$url"; then
    rm -f "$hdrf"
    log "Modele $name : Hugging Face injoignable ou reponse inattendue ; keryx-miner le telechargera lui-meme (IPFS)."
    return 1
  fi
  if ! parse_zip_head "$hdrf" || [[ ! "$zip_folder" =~ ^[A-Za-z0-9._-]+$ ]]; then
    rm -f "$hdrf"
    log "Modele $name : zip au format inattendu ; keryx-miner le telechargera lui-meme (IPFS)."
    return 1
  fi
  rm -f "$hdrf"

  dir="$models_root/$zip_folder"
  dest="$dir/model.gguf"
  part="$dest.partial"
  layout="$part.layout"
  mkdir -p "$dir" || { log "Modele $name : impossible de creer $dir."; return 1; }
  if [[ -f "$dest" ]]; then
    have=$(stat -c%s "$dest")
    if (( have == zip_size )); then
      log "Modele $name : deja telecharge ($(gb "$zip_size") Go)."
      return 0
    fi
    (( have > zip_size )) && rm -f "$dest"
  fi

  # Segments : $dl_conns parts egales de model.gguf (positions dans le fichier final).
  seg_s=()
  seg_l=()
  l=$(( (zip_size + dl_conns - 1) / dl_conns ))
  for ((i = 0; i < dl_conns; i++)); do
    s=$((i * l))
    c=$((zip_size - s))
    (( c > l )) && c=$l
    (( c < 0 )) && c=0
    seg_s+=("$s")
    seg_l+=("$c")
  done

  # Un telechargement partiel d'une autre forme (autre version du modele, autre
  # decoupage) est jete ; un model.gguf partiel (ancienne version de l'image, ou
  # keryx-miner) est repris comme debut du fichier.
  want="$zip_size $zip_start $dl_conns"
  if [[ -f "$part" ]] && [[ "$(cat "$layout" 2>/dev/null)" != "$want" || $(stat -c%s "$part") -ne $zip_size ]]; then
    rm -f "$part" "$part".seg* "$layout"
    log "Modele $name : ancien telechargement partiel incompatible, efface."
  fi
  if [[ ! -f "$part" ]]; then
    prefix=0
    if [[ -f "$dest" ]]; then
      prefix=$(stat -c%s "$dest")
      mv -f -- "$dest" "$part" || return 1
    fi
    truncate -s "$zip_size" "$part" || { log "Modele $name : impossible de creer $part."; return 1; }
    for ((i = 0; i < dl_conns; i++)); do
      c=$((prefix - seg_s[i]))
      (( c < 0 )) && c=0
      (( c > seg_l[i] )) && c=${seg_l[i]}
      echo "$c" > "$part.seg$i"
    done
    echo "$want" > "$layout"
  fi

  have=0
  for ((i = 0; i < dl_conns; i++)); do
    c=$(cat "$part.seg$i" 2>/dev/null || echo 0)
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    have=$((have + c))
  done
  avail=$(df -PB1 "$dir" | awk 'NR == 2 { print $4 }')
  if (( avail < zip_size - have + 1000000000 )); then
    log "Modele $name : ERREUR, disque insuffisant : il faut $(gb $((zip_size - have))) Go (+1 Go de marge), il reste $(gb "$avail") Go. Prends plus de disque sur l'instance."
    return 1
  fi
  if (( have > 0 )); then
    log "Modele $name : reprise a $(gb "$have") / $(gb "$zip_size") Go depuis Hugging Face ($dl_conns connexions)..."
  else
    log "Modele $name : telechargement de $(gb "$zip_size") Go depuis Hugging Face vers $dest ($dl_conns connexions)..."
  fi

  t0=$(date +%s)
  have0=$have
  phase=download
  progress_loop "$name" "$part" "$zip_size" &
  prog=$!
  for ((i = 0; i < dl_conns; i++)); do
    seg_worker "$i" &
    wpids+=($!)
  done
  for i in "${wpids[@]}"; do
    wait "$i"
  done
  kill "$prog" 2>/dev/null
  wait "$prog" 2>/dev/null
  phase=""

  have=0
  for ((i = 0; i < dl_conns; i++)); do
    c=$(cat "$part.seg$i" 2>/dev/null || echo 0)
    have=$((have + c))
  done
  if (( have != zip_size )) || [[ "$(head -c 4 "$part")" != GGUF ]]; then
    log "Modele $name : fichier incoherent apres telechargement ; efface, keryx-miner le telechargera lui-meme (IPFS)."
    rm -f "$part" "$part".seg* "$layout"
    return 1
  fi
  mv -f -- "$part" "$dest" && rm -f "$part".seg* "$layout"
  t0=$(( $(date +%s) - t0 ))
  awk -v n="$name" -v b=$((zip_size - have0)) -v t="$t0" 'BEGIN {
    if (t < 1) t = 1
    printf "[vastkeryx] Modele %s : telecharge en %d min %02d s (%.0f Mo/s en moyenne) ; keryx-miner va verifier son empreinte.\n", n, t / 60, t % 60, b / 1e6 / t }'
  return 0
}

# --- Test de connexion au noeud ou a la pool (informatif) -------------------------
# Avant le telechargement : la cible de keryx-miner repond-elle, et en combien de
# temps ? (a 10 blocs par seconde, plus le noeud est loin, plus des blocs arrivent
# trop tard). Le resultat est seulement affiche : la suite demarre quoi qu'il arrive.
ms_now() { date +%s%3N; }

check_connection() {
  local target hp host port port_opt def_port kind urlhost t0 rc tcp_ms req resp hdrs out http ttfb ms ver gst gmsg line
  target="${node:-127.0.0.1}"
  port_opt=$(opt_value "--port|-p" "${gpu_user[@]}")
  if has_opt --testnet "${gpu_user[@]}"; then def_port=22210; else def_port=22110; fi
  case "$target" in
    stratum+tcp://*) kind=pool; hp="${target#stratum+tcp://}" ;;
    grpc://*)        kind=node; hp="${target#grpc://}" ;;
    *://*)           log "Connexion : adresse $target non reconnue (ni grpc:// ni stratum+tcp://), pas de test."; return 0 ;;
    *)               kind=node; hp="$target" ;;
  esac
  hp="${hp%%/*}"
  if [[ "$hp" == *:* ]]; then
    host="${hp%:*}"
    port="${hp##*:}"
  else
    host="$hp"
    port="${port_opt:-$def_port}"
  fi
  host="${host#[}"
  host="${host%]}"
  urlhost="$host"
  [[ "$host" == *:* ]] && urlhost="[$host]"
  local what="noeud" the="le noeud"
  [[ $kind == pool ]] && what="pool" the="la pool"

  # 1. Connexion TCP (environ un aller-retour reseau).
  t0=$(ms_now)
  timeout 10 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null
  rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 124 ]]; then
      log "Connexion : ERREUR, $the $host:$port ne repond pas (rien en 10 s). Verifie l'adresse dans GPU_ARGS et que $the est en marche. Le demarrage continue quand meme."
    else
      log "Connexion : ERREUR, impossible de joindre $the $host:$port (connexion refusee ou adresse introuvable). Verifie l'adresse et le port dans GPU_ARGS. Le demarrage continue quand meme."
    fi
    return 0
  fi
  tcp_ms=$(( $(ms_now) - t0 ))
  log "Connexion : $what $host:$port joignable (connexion en $tcp_ms ms)."

  if [[ $kind == node ]]; then
    # 2. Requete GetInfo en gRPC, comme keryx-miner : KaspadMessage { getInfoRequest (1063) }.
    req=$(mktemp); resp=$(mktemp); hdrs=$(mktemp)
    printf '\x00\x00\x00\x00\x03\xba\x42\x00' > "$req"
    out=$(curl -sS --http2-prior-knowledge --max-time 10 -X POST \
            -H 'content-type: application/grpc' -H 'te: trailers' \
            --data-binary @"$req" -D "$hdrs" -o "$resp" -w '%{http_code} %{time_starttransfer}' \
            "http://$urlhost:$port/protowire.RPC/MessageStream" 2>/dev/null)
    read -r http ttfb <<< "$out"
    ms=$(awk -v t="${ttfb:-0}" 'BEGIN { printf "%d", t * 1000 }')
    gst=$(tr -d '\r' < "$hdrs" | awk -F': *' 'tolower($1) == "grpc-status" { print $2 }' | tail -n 1)
    gmsg=$(tr -d '\r' < "$hdrs" | awk -F': *' 'tolower($1) == "grpc-message" { print $2 }' | tail -n 1)
    if [[ "$http" == 200 && $(stat -c%s "$resp") -gt 5 ]]; then
      ver=$(grep -aoE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z._-]*' "$resp" | head -n 1)
      log "Connexion : le noeud repond a GetInfo en $ms ms${ver:+ (version $ver)}."
    elif [[ "$http" == 200 && "$gst" == 12 ]]; then
      log "Connexion : ATTENTION, le port $port parle gRPC mais ne connait pas les requetes RPC : est-ce bien le port RPC du noeud (pas le port P2P) ?"
    elif [[ "$http" == 200 ]]; then
      log "Connexion : ATTENTION, le noeud accepte la connexion gRPC mais n'a pas repondu a GetInfo en 10 s${gst:+ (grpc-status $gst${gmsg:+ : $gmsg})} : noeud surcharge ou en cours de synchronisation ?"
    else
      log "Connexion : ATTENTION, le port $port repond mais pas comme un noeud gRPC (HTTP ${http:-?}) : verifie que c'est le port RPC du noeud."
    fi
    rm -f "$req" "$resp" "$hdrs"
  else
    # 2. Demande d'abonnement stratum : une pool repond par une ligne JSON.
    out=$(timeout 15 bash -c '
      exec 3<>"/dev/tcp/$1/$2" || exit 2
      t0=$(date +%s%3N)
      printf "%s\n" "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"vastkeryx-test\"]}" >&3
      IFS= read -r -t 10 line <&3 || exit 3
      echo "$(( $(date +%s%3N) - t0 )) $line"
    ' _ "$host" "$port" 2>/dev/null)
    ms="${out%% *}"
    line="${out#* }"
    line="${line#"${line%%[![:space:]]*}"}"
    # Une vraie reponse stratum est une ligne JSON ({"id":1,...}) ; un serveur web,
    # lui, repond par une ligne « HTTP/1.x ... » qui peut recopier la requete.
    if [[ "$ms" =~ ^[0-9]+$ && "$line" == '{'* && "$line" == *'"id"'* ]]; then
      log "Connexion : la pool repond (stratum) en $ms ms."
    else
      log "Connexion : ATTENTION, le port $port est ouvert mais ne repond pas comme une pool stratum (rien de lisible en 10 s)."
    fi
  fi
  return 0
}

if [[ $dry_run -eq 1 ]]; then
  check_connection
  log "Modele(s) pour ce palier (${wanted_tiers[*]}) : ${wanted_models[*]} -> $models_root (depuis Hugging Face)"
  if [[ -n "$escrow_key" ]]; then
    log "Escrow : KERYX_ESCROW_KEY valide, serait ecrite dans $key_file (DRY_RUN : rien n'est ecrit)."
  else
    log "Escrow : KERYX_ESCROW_KEY absente, keryx-miner utilise ou cree $key_file."
  fi
  if [[ $pool_mode -eq 1 ]]; then
    log "Escrow : mode pool (stratum), pas de recuperation."
  elif [[ -z "$escrow_key" && ! -f "$key_file" ]]; then
    log "Escrow : pas de recuperation (pas encore de cle)."
  else
    log "Escrow : recuperation (conteneur neuf) : $(show_cmd "${recover_cmd[@]}")"
  fi
  log "GPU (keryx) : $(show_cmd "${gpu_cmd[@]}")"
  exit 0
fi

if ! ls /dev/nvidia* >/dev/null 2>&1 && [[ ! -e /usr/lib/x86_64-linux-gnu/libcuda.so.1 ]]; then
  log "ATTENTION : aucun GPU NVIDIA visible dans le conteneur (lancer avec --gpus all)."
fi

# Un arret du conteneur est transmis au mineur (SIGTERM), qui a le temps
# d'enregistrer son etat avant de quitter.
pid=0
phase=""
stop() {
  # Pendant la recuperation, rien n'est encore ecrit (le mineur enregistre l'etat
  # d'un coup, a la fin) : on quitte sans attendre la reponse de l'API.
  if [[ "$phase" == recover ]]; then
    log "Arret demande pendant la recuperation escrow : abandonnee."
    exit 0
  fi
  # Pendant le telechargement du modele : le fichier partiel reste, il sera repris.
  if [[ "$phase" == download ]]; then
    log "Arret demande pendant le telechargement du modele : il reprendra au prochain demarrage."
    exit 0
  fi
  log "Arret demande, fermeture du mineur..."
  if [[ $pid -ne 0 ]]; then
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  exit 0
}
trap stop TERM INT

check_connection
[[ -n "$escrow_key" ]] && install_escrow_key
recover_escrow
for m in "${wanted_models[@]}"; do
  fetch_model "$m"
done

# --- Lancement et relance --------------------------------------------------------
log "GPU (keryx) : $(show_cmd "${gpu_cmd[@]}")"
while true; do
  "${gpu_cmd[@]}" &
  pid=$!
  wait "$pid"
  code=$?
  pid=0
  log "keryx-miner s'est arrete (code $code). Relance dans ${delay}s."
  sleep "$delay" & wait $!
done
