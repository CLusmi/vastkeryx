# vastkeryx

Image Docker pour miner du **Keryx** sur des machines louées sur **vast.ai** (GPU NVIDIA),
avec le mineur officiel [keryx-miner](https://github.com/Keryx-Labs/keryx-miner).

Deux variables, rien de plus : `GPU_MINER=keryx` et `GPU_ARGS`, qui contient les
arguments de keryx-miner **tels quels**, dans sa syntaxe d'origine. L'image n'ajoute
aucune option.
Image publiée : `clusmi/vastkeryx:latest` (publique).

## Comment l'image est construite

Le workflow GitHub (`.github/workflows/build.yml`) :

1. cherche la **dernière release stable** de `Keryx-Labs/keryx-miner` (ou celle que tu
   indiques dans le champ *version* de **Run workflow**, par exemple `v0.5.7-PoM`) ;
2. télécharge l'archive Linux (`keryx-miner-<version>-linux-amd64.zip`) et **vérifie son
   empreinte SHA-256** (celle que GitHub a enregistrée quand Keryx-Labs a publié le
   fichier) : si elle ne correspond pas, la construction échoue ;
3. construit l'image (Ubuntu 24.04) et l'envoie sur Docker Hub sous **deux étiquettes** :
   `clusmi/vastkeryx:latest` et une étiquette datée, par exemple
   `clusmi/vastkeryx:2026-10-08-1800`.

La version incluse s'affiche dans le résumé du workflow, et au démarrage du conteneur.
Pour passer à une nouvelle version du mineur, relance simplement le workflow, puis
`recycle` l'instance sur vast.ai pour qu'elle re-télécharge `latest`.

## Mise en place (une seule fois)

1. **Docker Hub** : dépôt `vastkeryx` (public).
2. **GitHub** : *Settings → Secrets and variables → Actions* : `DOCKERHUB_USERNAME`
   (`clusmi`) et `DOCKERHUB_TOKEN` (les mêmes que pour rentingminers).
3. Onglet **Actions** → *Construire et publier l'image* → **Run workflow**.

## Variables

| Variable | Valeurs | Rôle |
|---|---|---|
| `GPU_MINER` | `keryx` (seule valeur) | |
| `GPU_ARGS` | | arguments de keryx-miner, tels quels |
| `RESTART_DELAY` | `10` | secondes avant relance du mineur s'il s'arrête |
| `DRY_RUN` | | `1` : affiche la commande finale sans miner |

`GPU_MINER` et `GPU_ARGS` sont obligatoires tous les deux : si l'un manque, rien ne
démarre et le log dit pourquoi.

Dans le template vast.ai, le plus simple est la section **Environment Variables** : une
case pour le nom, une pour la valeur, **sans guillemets**. Dans le champ « Docker
Options », la syntaxe est `-e GPU_ARGS="--keryxd-address ... --mining-address ..."`, avec
le `-e` et des guillemets autour de la valeur. Si vast.ai garde ces guillemets dans la
valeur, l'image les retire.

Template prêt à copier : voir [TEMPLATES.txt](TEMPLATES.txt).

## Ce qu'il faut savoir

- **Machines de 8 cartes** : keryx-miner mine sur toutes les cartes visibles et choisit le
  palier de modèle IA de chaque carte selon sa mémoire (les options `--very-light`,
  `--light`, `--high`, `--very-high` et `--force-model` vont dans `GPU_ARGS`).
- **Modèle IA** : il est téléchargé au premier démarrage, une seule fois pour toutes les
  cartes, dans `/opt/miners/keryx/models`. Sur des cartes de 32 Go (RTX 5090), c'est
  Kimi-Linear-48B, soit 30 Go : prévois **au moins 50 Go de disque** sur l'instance.
- **Fichiers du mineur** (`escrow.key`, `escrow_state.json`…) : ils sont écrits dans le
  dossier de travail du conteneur, `/opt/miners/work`.
- **Logs** : tout ce qu'écrit keryx-miner apparaît dans les logs de l'instance vast.ai ;
  les lignes de l'image commencent par `[vastkeryx]`.
- **Relance** : si keryx-miner s'arrête, il est relancé après `RESTART_DELAY` secondes.
  Un arrêt de l'instance lui est transmis proprement (SIGTERM).

## Tester sans miner

- `DRY_RUN=1` : la commande complète s'affiche dans les logs, puis le conteneur s'arrête.
- `docker run --rm clusmi/vastkeryx --help` : aide de keryx-miner (il lui faut un GPU
  NVIDIA, donc `--gpus all`).
- `docker run --rm -it clusmi/vastkeryx bash` : un shell dans l'image.
