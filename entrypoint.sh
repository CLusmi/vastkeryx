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

if [[ $dry_run -eq 1 ]]; then
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
  log "Arret demande, fermeture du mineur..."
  if [[ $pid -ne 0 ]]; then
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  exit 0
}
trap stop TERM INT

[[ -n "$escrow_key" ]] && install_escrow_key
recover_escrow

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
