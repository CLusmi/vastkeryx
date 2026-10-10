# Image de minage pour machines louees sur vast.ai :
#   GPU NVIDIA : keryx-miner   (GPU_MINER=keryx, GPU_ARGS, KERYX_ESCROW_KEY facultatif)
#   CPU        : XMRig         (CPU_MINER=xmrig, CPU_ARGS)
# Un cote ne demarre que si son mineur ET ses arguments sont renseignes.
#
# Les versions, URL et empreintes sont fournies par le workflow GitHub
# (scripts/resolve-versions.sh). Chaque archive est telechargee depuis la release
# officielle du mineur et verifiee avant installation.

# ---------------------------------------------------------------------------
# Etape 1 : telechargement et verification des mineurs
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS fetch

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

ARG KERYX_VERSION
ARG KERYX_URL
ARG KERYX_SHA256
ARG XMRIG_VERSION
ARG XMRIG_URL
ARG XMRIG_SHA256

COPY scripts/fetch-miner.sh /usr/local/bin/fetch-miner
RUN chmod +x /usr/local/bin/fetch-miner \
    && mkdir -p /opt/miners \
    && fetch-miner keryx "$KERYX_VERSION" "$KERYX_URL" "$KERYX_SHA256" \
    && fetch-miner xmrig "$XMRIG_VERSION" "$XMRIG_URL" "$XMRIG_SHA256"

# ---------------------------------------------------------------------------
# Etape 2 : image finale, sans outils de telechargement
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# ca-certificates : connexions TLS (telechargement des modeles IA, IPFS).
# curl : telechargement du modele IA depuis Hugging Face par l'entrypoint.
# libgomp1 : demande par le moteur d'inference (libkeryx-llama.so).
# Le pilote NVIDIA (libcuda) n'est PAS dans l'image : vast.ai l'injecte au
# lancement. Les librairies CUDA (cuBLAS, cudart) sont livrees avec le mineur.
# XMRig (version statique) est autonome.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /opt/miners /opt/miners
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && mkdir -p /opt/miners/work

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    RESTART_DELAY=10

LABEL org.opencontainers.image.title="vastkeryx" \
      org.opencontainers.image.description="keryx-miner (GPU NVIDIA) + XMRig (CPU, facultatif) pour vast.ai ; GPU_MINER=keryx + GPU_ARGS, CPU_MINER=xmrig + CPU_ARGS, cle escrow commune dans KERYX_ESCROW_KEY"

WORKDIR /opt/miners/work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
