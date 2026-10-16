#!/bin/bash
#
# Importa os dados exportados do studio1 para o ambiente da AIBA.
#
# Roda NA VM DA AIBA, a partir da raiz do projeto, com o ambiente já no ar:
#   ./scripts/migracao/importar.sh ~/mhb-migracao-20260715-201500
#
# Diferença fundamental em relação à origem: lá os dados viviam num bind mount
# (/root/system/mhb), aqui vivem em VOLUMES NOMEADOS, porque a imagem é
# imutável. Não dá para extrair direto no filesystem do host: é preciso montar
# cada volume num contêiner auxiliar e extrair lá dentro.
#
set -euo pipefail

PACOTE="${1:-}"
# O padrão é o ambiente da AIBA. O QA do studio1 divide o host com os
# containers antigos (mhb, mhb_queue, mhb_cron), que ficam parados para
# rollback e ocupam esses nomes, então lá projeto, compose e containers vêm
# por variável de ambiente.
PROJETO="${PROJETO:-mhb}"
ARQUIVO_COMPOSE="${ARQUIVO_COMPOSE:-docker-compose.aiba.yml}"
CT_APP="${CT_APP:-mhb}"
CT_DB="${CT_DB:-mhb_db}"
CT_QUEUE="${CT_QUEUE:-mhb_queue}"
CT_CRON="${CT_CRON:-mhb_cron}"
COMPOSE="docker compose -f ${ARQUIVO_COMPOSE} -p ${PROJETO}"
# www-data na imagem php:apache. Usamos o número, não o nome: o contêiner
# auxiliar (alpine) não tem um usuário chamado www-data.
UID_APP=33
GID_APP=33

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
aviso(){ printf '\033[1;33m    %s\033[0m\n' "$*"; }
erro() { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$PACOTE" ] || erro "uso: $0 <diretorio-do-pacote>"
[ -d "$PACOTE" ] || erro "pacote não encontrado: $PACOTE"
PACOTE=$(cd "$PACOTE" && pwd)
[ -f "$ARQUIVO_COMPOSE" ] || erro "rode a partir da raiz do projeto."
[ -f "${PACOTE}/MANIFESTO.txt" ] || erro "MANIFESTO.txt ausente — o pacote está incompleto."

# --- Integridade -----------------------------------------------------------
log "Conferindo checksums"
( cd "$PACOTE" && sha256sum -c SHA256SUMS ) || erro "checksum inválido: a transferência corrompeu o pacote."

# shellcheck disable=SC1090
source "${PACOTE}/MANIFESTO.txt"
log "Manifesto: ${BANCO_TABELAS} tabelas, ${TILES_ARQUIVOS} tiles, ${STORAGE_APP_ARQUIVOS} arquivos em storage/app"

# --- Ambiente no ar? -------------------------------------------------------
estado_db=$(docker inspect --format '{{.State.Health.Status}}' "$CT_DB" 2>/dev/null || echo "ausente")
[ "$estado_db" = "healthy" ] || erro "o banco não está saudável (estado: ${estado_db}). Rode ./deploy.sh primeiro."

env_get() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
DB_NAME=$(env_get DB_DATABASE); DB_USER=$(env_get DB_USERNAME); DB_PASS=$(env_get DB_PASSWORD)
[ -n "$DB_NAME" ] || erro "não consegui ler DB_DATABASE do .env"

aviso "Isto SOBRESCREVE o banco '${DB_NAME}' e os volumes de dados deste ambiente."
read -r -p "    Confirma a importação? (digite: sim) " confirma
[ "$confirma" = "sim" ] || erro "cancelado pelo usuário."

# --- Para os escritores ----------------------------------------------------
# O worker e o cron gravam durante a importação e corromperiam o resultado.
log "Parando fila e agendador durante a importação"
docker stop "$CT_QUEUE" "$CT_CRON" > /dev/null 2>&1 || true

# --- Banco -----------------------------------------------------------------
log "Importando o banco (${BANCO_TABELAS} tabelas)"
zcat "${PACOTE}/banco.sql.gz" \
    | docker exec -i -e MYSQL_PWD="$DB_PASS" "$CT_DB" \
        mariadb --user="$DB_USER" --default-character-set=utf8mb4 "$DB_NAME"

tabelas_agora=$(docker exec -e MYSQL_PWD="$DB_PASS" "$CT_DB" \
    mariadb --user="$DB_USER" --skip-column-names -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'" | tr -d '[:space:]')
log "Banco importado: ${tabelas_agora} tabelas"

# --- Volumes ---------------------------------------------------------------
# Cada volume é montado em /destino num alpine descartável, que extrai o tar e
# ajusta o dono para o uid da aplicação. O tar carrega o diretório na raiz
# (ex.: tiles/), daí o --strip-components=1.
restaurar_volume() {
    local volume="$1" arquivo="$2" descricao="$3"
    if [ ! -f "${PACOTE}/${arquivo}" ]; then
        aviso "pulando ${descricao}: ${arquivo} não está no pacote"
        return
    fi
    log "Restaurando ${descricao} -> volume ${volume}"
    docker run --rm \
        -v "${PROJETO}_${volume}:/destino" \
        -v "${PACOTE}:/pacote:ro" \
        alpine:3 sh -c "
            set -e
            rm -rf /destino/* /destino/.[!.]* 2>/dev/null || true
            tar xzf /pacote/${arquivo} -C /destino --strip-components=1
            chown -R ${UID_APP}:${GID_APP} /destino
        "
    local qtd
    qtd=$(docker run --rm -v "${PROJETO}_${volume}:/d:ro" alpine:3 find /d -type f | wc -l)
    printf '    %s: %s arquivos\n' "$descricao" "$qtd"
}

restaurar_volume "tiles"   "tiles.tar.gz"   "camadas de mapa"
restaurar_volume "geojson" "geojson.tar.gz" "camadas GeoJSON"

# storage_app é o único cujo tar traz "app/" na raiz, e o volume JÁ é o app/.
log "Restaurando storage/app -> volume ${PROJETO}_storage_app"
docker run --rm \
    -v "${PROJETO}_storage_app:/destino" \
    -v "${PACOTE}:/pacote:ro" \
    alpine:3 sh -c "
        set -e
        rm -rf /destino/* /destino/.[!.]* 2>/dev/null || true
        tar xzf /pacote/storage_app.tar.gz -C /destino --strip-components=1
        mkdir -p /destino/temp
        chown -R ${UID_APP}:${GID_APP} /destino
    "

# --- Religa ----------------------------------------------------------------
log "Subindo fila e agendador"
$COMPOSE up -d > /dev/null 2>&1

log "Aguardando o app"
for i in $(seq 1 24); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$CT_APP" 2>/dev/null || echo x)" = "healthy" ] && break
    [ "$i" = "24" ] && erro "o app não ficou saudável. Veja: docker logs ${CT_APP}"
    sleep 5
done

# Como www-data, o usuário da aplicação: como root, um arquivo que o artisan
# crie (o laravel.log, se uma migração gravar log) nasce root e a aplicação
# deixa de conseguir escrever nele. HOME=/tmp porque o tinker (psysh) grava a
# própria configuração no HOME, e o do www-data (/var/www) não é gravável.
ARTISAN="docker exec -u www-data -e HOME=/tmp $CT_APP php artisan"

$ARTISAN migrate --force
$ARTISAN optimize:clear
$ARTISAN storage:link 2>/dev/null || true
# O optimize:clear apaga também os caches de configuração e de rotas; sem
# refazê-los a aplicação funciona, mas relê tudo a cada requisição.
$ARTISAN config:cache
$ARTISAN route:cache

# --- Validação -------------------------------------------------------------
log "Validando contra o manifesto"
falhou=0

conferir() {
    local descricao="$1" esperado="$2" obtido="$3"
    if [ "$esperado" = "$obtido" ]; then
        printf '    \033[1;32mOK\033[0m   %-22s %s\n' "$descricao" "$obtido"
    else
        printf '    \033[1;31mFALHA\033[0m %-22s esperado %s, obtido %s\n' "$descricao" "$esperado" "$obtido"
        falhou=1
    fi
}

tiles_agora=$(docker exec "$CT_APP" find /var/www/html/public/tiles -type f 2>/dev/null | wc -l)
geojson_agora=$(docker exec "$CT_APP" find /var/www/html/public/geojson -type f 2>/dev/null | wc -l)
app_agora=$(docker exec "$CT_APP" find /var/www/html/storage/app -type f -not -path '*/temp/*' 2>/dev/null | wc -l)

conferir "tabelas do banco"  "$BANCO_TABELAS"        "$tabelas_agora"
conferir "tiles"             "$TILES_ARQUIVOS"       "$tiles_agora"
conferir "geojson"           "$GEOJSON_ARQUIVOS"     "$geojson_agora"
conferir "arquivos storage"  "$STORAGE_APP_ARQUIVOS" "$app_agora"

# A aplicação consegue mesmo ler os dados? Contagem de arquivo não prova isso.
log "Verificando o acesso da aplicação"
$ARTISAN tinker --execute='
    echo "estações no inventário: ".DB::table("hw_inventory_stations")->count().PHP_EOL;
    echo "leituras de telemetria: ".DB::table("hw_station_readings_telemetry")->count().PHP_EOL;
' 2>&1 | grep -E "estações|leituras" || aviso "não foi possível consultar as tabelas"

if [ "$falhou" = "1" ]; then
    erro "a validação encontrou divergências — NÃO aponte o DNS para cá ainda."
fi

log "Importação concluída e validada"
cat <<EOF

Antes do cutover de DNS, verifique manualmente:

  - abrir o mapa e conferir se as camadas renderizam
  - conferir se a coleta de satélite roda: docker logs ${CT_CRON}
    (o teste da porta 16003 do item 4.1 precisa estar liberado)
  - conferir a fila: docker exec -u www-data ${CT_APP} php artisan queue:failed

EOF
