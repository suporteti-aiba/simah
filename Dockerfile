# Imagem de produção do SIMAH — código embutido, sem bind mount.
#
# Substitui o DockerfileProduction, onde a imagem era só o runtime e o código
# chegava por scp + bind mount. Aquele modelo exigia rechown a cada boot
# (os arquivos chegavam com o dono do usuário de deploy) e tornava a versão em
# produção não rastreável. Aqui o código entra na imagem, que é imutável e
# identificada pelo SHA do commit.

# ---------------------------------------------------------------------------
# Stage 1 — dependências PHP
# ---------------------------------------------------------------------------
FROM composer:2.8 AS vendor

WORKDIR /app

COPY composer.json composer.lock ./

# --no-scripts: os scripts do Laravel (package:discover) precisam do código
# completo, que só existe no estágio final. São executados lá.
RUN composer install \
        --no-dev \
        --no-scripts \
        --no-interaction \
        --prefer-dist \
        --optimize-autoloader

# ---------------------------------------------------------------------------
# Stage 2 — assets front-end
# ---------------------------------------------------------------------------
FROM node:22-slim AS assets

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY vite.config.js ./
COPY resources ./resources

# Hoje só welcome.blade.php usa @vite e nenhuma rota a renderiza, então o
# manifest nunca foi gerado. Buildar aqui custa segundos e evita que a view
# quebre caso volte a ser usada — sem levar node para o runtime.
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 3 — runtime
# ---------------------------------------------------------------------------
FROM php:8.3.20-apache

LABEL maintainer="pedro.nascimento@lepoti.tech"
LABEL org.opencontainers.image.source="https://github.com/studio1-tech/simah-web"
LABEL org.opencontainers.image.description="SIMAH — Sistema de Monitoramento Hidrológico"

ENV TZ="America/Bahia"
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

COPY ./docker/php.ini /usr/local/etc/php/php.ini
COPY ./docker/php/custom.ini /usr/local/etc/php/conf.d/custom.ini
COPY ./docker/apache2.conf /etc/apache2/apache2.conf
COPY ./docker/000-default.conf /etc/apache2/sites-available/000-default.conf

# Runtime enxuto: sem nodejs/npm (os assets vêm prontos do stage 2), sem
# composer e sem git. Só o que a aplicação executa:
#   - gdal-bin ....... geração de tiles e conversão de shapefiles
#   - default-jre .... cliente LRGS (recepção de dados de satélite)
#   - python3 ........ previsão de vazão (numpy/pandas)
#   - cron ........... container de agendamento (mesma imagem)
#   - curl ........... healthcheck e jobs agendados
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        cron \
        curl \
        gdal-bin \
        gdal-data \
        libgdal-dev \
        default-jre-headless \
        python3 \
        python3-numpy \
        python3-pandas \
        libzip-dev \
        libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# intl: sem ela, Number::format() lança RuntimeException e quebra comandos do
# framework (artisan db:show, entre outros). Faltava na imagem anterior.
RUN docker-php-ext-configure intl \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql zip intl \
    && a2enmod rewrite headers \
    && sed -ri -e 's/^([ \t]*)(<\/VirtualHost>)/\1\tHeader set Access-Control-Allow-Origin "*"\n\1\2/g' \
        /etc/apache2/sites-available/*.conf

WORKDIR /var/www/html

COPY --chown=www-data:www-data . .
COPY --from=vendor --chown=www-data:www-data /app/vendor ./vendor
COPY --from=assets --chown=www-data:www-data /app/public/build ./public/build

# Diretórios de escrita. Em produção estes caminhos recebem volumes; os mkdir
# garantem que a imagem funcione sem eles (ex.: rodar a imagem isolada).
RUN mkdir -p \
        storage/app/temp \
        storage/app/uploads \
        storage/app/lrgs/temp \
        storage/app/shapefiles \
        storage/app/hw_station_drainages \
        storage/framework/cache \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs/dcp \
        public/tiles \
        public/geojson \
    && chown -R www-data:www-data storage bootstrap/cache public/tiles public/geojson lrgs \
    && chmod -R 775 storage bootstrap/cache public/tiles public/geojson \
    && chmod +x resources/scripts/*.py

# O cliente LRGS regrava lrgs/MessageBrowser.sc a cada consulta, então lrgs/
# precisa ser gravável. Não vira volume: o conteúdo é descartável (o .sc é
# regerado) e os JARs devem vir da imagem.

# Descoberta de pacotes DENTRO da imagem. É o passo que o stage do composer não
# pôde executar (--no-scripts, pois lá só existiam composer.json/lock). Precisa
# rodar aqui, com o código completo e apenas as dependências de produção
# presentes, para o cache refletir o que o runtime realmente carrega.
RUN php artisan package:discover --ansi \
    && php artisan config:clear

COPY ./docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

# Usa o endpoint /up que o Laravel já expõe (health: '/up' em bootstrap/app.php)
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS http://localhost/up || exit 1

ENTRYPOINT ["entrypoint"]
CMD ["apache2-foreground"]
