#!/bin/bash
#
# Deploy do SIMAH na VM da AIBA.
#
# A conexão parte SEMPRE de dentro para fora: esta VM busca a imagem no
# registro. Ninguém de fora conecta aqui. É o que dispensa expor SSH à
# internet — ver item 6 do DRT-SIMAH-001.
#
# Uso:
#   ./deploy.sh              # sobe a tag configurada no .env (padrão: latest)
#   ./deploy.sh sha-a1b2c3d  # sobe uma tag específica
#   ./deploy.sh --rollback   # volta para a tag anterior registrada
#
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE="docker compose -f docker-compose.aiba.yml -p mhb"
ARQUIVO_TAG_ANTERIOR=".deploy-tag-anterior"
ESPACO_MINIMO_GB=5

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
erro() { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f .env ] || erro "arquivo .env não encontrado. Copie de .env.example e preencha."

# --- Espaço em disco -------------------------------------------------------
# A importação da maior camada gera ~3 GB de intermediários e a imagem tem
# ~2 GB. Um deploy sem espaço deixa o ambiente pela metade.
livre_gb=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
if [ "$livre_gb" -lt "$ESPACO_MINIMO_GB" ]; then
    erro "espaço insuficiente: ${livre_gb}GB livres, mínimo ${ESPACO_MINIMO_GB}GB."
fi
log "Espaço em disco: ${livre_gb}GB livres"

# --- Resolução da tag ------------------------------------------------------
if [ "${1:-}" = "--rollback" ]; then
    [ -f "$ARQUIVO_TAG_ANTERIOR" ] || erro "sem tag anterior registrada para rollback."
    TAG=$(cat "$ARQUIVO_TAG_ANTERIOR")
    log "ROLLBACK para a tag: $TAG"
elif [ -n "${1:-}" ]; then
    TAG="$1"
else
    TAG=$(grep -E '^IMAGE_TAG=' .env 2>/dev/null | cut -d= -f2- || true)
    TAG="${TAG:-latest}"
fi

REGISTRY=$(grep -E '^IMAGE_REGISTRY=' .env 2>/dev/null | cut -d= -f2- || true)
REGISTRY="${REGISTRY:-ghcr.io/studio1-tech/simah-web}"

# --- Registra a tag atual para permitir rollback ---------------------------
tag_atual=$(docker inspect --format '{{index .Config.Image}}' mhb 2>/dev/null | awk -F: '{print $NF}' || true)
if [ -n "$tag_atual" ] && [ "$tag_atual" != "$TAG" ]; then
    echo "$tag_atual" > "$ARQUIVO_TAG_ANTERIOR"
    log "Tag atual registrada para rollback: $tag_atual"
fi

# --- Pull ------------------------------------------------------------------
log "Baixando ${REGISTRY}:${TAG}"
IMAGE_TAG="$TAG" IMAGE_REGISTRY="$REGISTRY" $COMPOSE pull

# --- Sobe ------------------------------------------------------------------
log "Subindo os serviços"
IMAGE_TAG="$TAG" IMAGE_REGISTRY="$REGISTRY" $COMPOSE up -d --remove-orphans

# --- Aguarda o app ficar saudável ------------------------------------------
log "Aguardando o app responder"
for i in $(seq 1 30); do
    estado=$(docker inspect --format '{{.State.Health.Status}}' mhb 2>/dev/null || echo "starting")
    [ "$estado" = "healthy" ] && break
    [ "$i" = "30" ] && erro "app não ficou saudável em 150s. Veja: docker logs mhb"
    sleep 5
done
log "App saudável"

# --- Migrações e cache -----------------------------------------------------
# Rodam aqui, uma vez por deploy, e não no entrypoint: os três contêineres
# compartilham a imagem e disputariam o banco ao subir juntos.
#
# Como www-data, o mesmo usuário da aplicação: como root, qualquer arquivo que
# o artisan crie (o laravel.log, se uma migração gravar log) nasce root, e a
# aplicação deixa de conseguir escrever nele.
ARTISAN="docker exec -u www-data mhb php artisan"

log "Aplicando migrações"
$ARTISAN migrate --force

log "Regenerando caches"
$ARTISAN optimize:clear
$ARTISAN storage:link 2>/dev/null || true
$ARTISAN config:cache
$ARTISAN route:cache

log "Limpando restos de importações interrompidas"
$ARTISAN temp:prune

# --- Resultado -------------------------------------------------------------
log "Estado final"
$COMPOSE ps
printf '\n\033[1;32mDeploy concluído — tag %s\033[0m\n' "$TAG"
printf 'Rollback, se necessário: ./deploy.sh --rollback\n\n'
