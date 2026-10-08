#!/usr/bin/env bash
# Lance keryx-miner sur les GPU NVIDIA. Les arguments de GPU_ARGS sont passes
# au mineur tels quels : l'image n'ajoute aucune option.
#
# Variables :
#   GPU_MINER      keryx (seule valeur possible)
#   GPU_ARGS       arguments de keryx-miner
#                  ex. --keryxd-address IP:PORT --mining-address keryx:ADRESSE
#   RESTART_DELAY  secondes avant relance du mineur s'il s'arrete (defaut 10)
#   DRY_RUN=1      affiche la commande finale sans lancer le mineur
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

present=()
absent=()
for name in GPU_MINER GPU_ARGS; do
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

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

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
gpu_cmd=("$keryx" "${gpu_user[@]}")
log "GPU (keryx) : $(show_cmd "${gpu_cmd[@]}")"

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  exit 0
fi

if ! ls /dev/nvidia* >/dev/null 2>&1 && [[ ! -e /usr/lib/x86_64-linux-gnu/libcuda.so.1 ]]; then
  log "ATTENTION : aucun GPU NVIDIA visible dans le conteneur (lancer avec --gpus all)."
fi

# --- Lancement et relance --------------------------------------------------------
# Un arret du conteneur est transmis au mineur (SIGTERM), qui a le temps
# d'enregistrer son etat avant de quitter.
pid=0
stop() {
  log "Arret demande, fermeture du mineur..."
  if [[ $pid -ne 0 ]]; then
    kill -TERM "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  exit 0
}
trap stop TERM INT

while true; do
  "${gpu_cmd[@]}" &
  pid=$!
  wait "$pid"
  code=$?
  pid=0
  log "keryx-miner s'est arrete (code $code). Relance dans ${delay}s."
  sleep "$delay" & wait $!
done
