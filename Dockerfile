# Image de minage Keryx pour GPU loues sur vast.ai :
#   GPU_MINER=keryx
#   GPU_ARGS=<arguments de keryx-miner, passes tels quels>
#   KERYX_ESCROW_KEY=<facultatif : meme cle escrow sur toutes les instances>
#
# La version, l'URL et l'empreinte de keryx-miner sont fournies par le workflow
# GitHub (scripts/resolve-versions.sh). L'archive est telechargee depuis la
# release officielle Keryx-Labs et verifiee avant installation.

# ---------------------------------------------------------------------------
# Etape 1 : telechargement et verification du mineur
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS fetch

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

ARG KERYX_VERSION
ARG KERYX_URL
ARG KERYX_SHA256

COPY scripts/fetch-miner.sh /usr/local/bin/fetch-miner
RUN chmod +x /usr/local/bin/fetch-miner \
    && mkdir -p /opt/miners \
    && fetch-miner "$KERYX_VERSION" "$KERYX_URL" "$KERYX_SHA256"

# ---------------------------------------------------------------------------
# Etape 2 : image finale, sans outils de telechargement
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
# ca-certificates : connexions TLS (telechargement des modeles IA, IPFS).
# libgomp1 : demande par le moteur d'inference (libkeryx-llama.so).
# Le pilote NVIDIA (libcuda) n'est PAS dans l'image : vast.ai l'injecte au
# lancement. Les librairies CUDA (cuBLAS, cudart) sont livrees avec le mineur.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /opt/miners /opt/miners
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && mkdir -p /opt/miners/work

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    RESTART_DELAY=10

LABEL org.opencontainers.image.title="vastkeryx" \
      org.opencontainers.image.description="keryx-miner (GPU NVIDIA) pour vast.ai ; GPU_MINER=keryx, arguments du mineur dans GPU_ARGS, cle escrow commune dans KERYX_ESCROW_KEY"

WORKDIR /opt/miners/work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
