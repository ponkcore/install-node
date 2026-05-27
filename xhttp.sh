#!/bin/bash
set -euo pipefail
# ============================================
# Remnawave Node Auto-Installer + Hardening
# ============================================
# Готов под xHTTP через Beeline-CDN, CDNvideo, TimeWeb-CDN
# Версия: 2026-05-27, актуально под Xray-core >= 26.3, Remnawave >= 2.7
# ============================================
# --- Ввод переменных ---
read -p "SSH порт [54333]: " SSH_PORT
SSH_PORT=${SSH_PORT:-54333}
read -p "Порт ноды (NODE_PORT) [5774]: " NODE_PORT
NODE_PORT=${NODE_PORT:-5774}
read -p "SECRET_KEY: " SECRET_KEY
if [ -z "$SECRET_KEY" ]; then echo "SECRET_KEY обязателен!"; exit 1; fi
read -p "Decoy домен (serverName для Angie, должна быть A-запись на этот IP): " DECOY_DOMAIN
if [ -z "$DECOY_DOMAIN" ]; then echo "Домен обязателен!"; exit 1; fi
read -p "IP панели Remnawave [150.251.138.43]: " PANEL_IP
PANEL_IP=${PANEL_IP:-150.251.138.43}
read -p "Имя админ-пользователя [adminpzfq]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-adminpzfq}
# --- xHTTP-параметры ---
echo ""
echo ">>> xHTTP-настройки (вставятся в шаблон в конце)"
read -p "Uplink HTTP Method (GET/POST/PATCH/PUT/OPTIONS) [PATCH]: " UPLINK_METHOD
UPLINK_METHOD=${UPLINK_METHOD:-PATCH}
UPLINK_METHOD=$(echo "$UPLINK_METHOD" | tr '[:lower:]' '[:upper:]')
read -p "xHTTP path [/api/v1/sync]: " XHTTP_PATH
XHTTP_PATH=${XHTTP_PATH:-/api/v1/sync}
XHTTP_PATH="/${XHTTP_PATH#/}"
read -p "CDN-домен Beeline (опц., типа xxxxxx.a.trbcdn.net): " CDN_DOMAIN
CDN_DOMAIN=${CDN_DOMAIN:-NEED_TO_FILL}
# --- Обновление системы ---
echo ">>> Обновление системы..."
apt update && apt upgrade -y && apt autoremove -y
# --- Docker ---
echo ">>> Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
else
    echo "Docker уже установлен, пропускаем"
fi
# --- Директории ---
echo ">>> Создание директорий..."
mkdir -p /opt/remnanode/angie
mkdir -p /var/log/remnanode
wget -qO- https://raw.githubusercontent.com/Jolymmiles/confluence-marzban-home/main/index.html > /opt/remnanode/angie/index.html
# --- Angie ---
echo ">>> Настройка Angie..."
cat > /opt/remnanode/angie/angie.conf << EOFANGIE
user angie;
worker_processes auto;
error_log /var/log/angie/error.log notice;
events {
    worker_connections 4096;
}
http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /var/log/angie/access.log main;
    resolver 1.1.1.1;
    acme_client vless https://acme-v02.api.letsencrypt.org/directory;
    # увеличенные header buffers - под xHTTP packet-up GET-режим (uplinkChunkSize до 7K)
    large_client_header_buffers 8 16k;
    client_header_buffer_size 4k;
    server {
        listen 80;
        listen [::]:80;
        server_name _;
        return 301 https://\$host\$request_uri;
    }
    server {
        listen 127.0.0.1:4123 ssl proxy_protocol;
        http2 on;
        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;
        server_name ${DECOY_DOMAIN};
        acme vless;
        ssl_certificate \$acme_cert_vless;
        ssl_certificate_key \$acme_cert_key_vless;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        location / {
            root /tmp;
            index index.html;
        }
    }
}
EOFANGIE
# --- Docker-compose ---
echo ">>> Настройка docker-compose..."
cat > /opt/remnanode/docker-compose.yml << EOFDC
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - ./angie/angie.conf:/etc/angie/angie.conf:ro
      - ./angie/index.html:/tmp/index.html:ro
      - angie-data:/var/lib/angie
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY="${SECRET_KEY}"
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - angie-data:/etc/angie-shared:ro
volumes:
  angie-data:
EOFDC
# --- Запуск Angie сначала (чтобы выпустить ACME) ---
echo ">>> Запуск Angie..."
cd /opt/remnanode && docker compose up -d angie
echo ">>> Ожидание выпуска ACME-сертификата (~120 сек)..."
CERT_READY=false
for i in {1..24}; do
    if docker exec angie test -f /var/lib/angie/acme/vless/certificate.pem 2>/dev/null \
       && docker exec angie test -f /var/lib/angie/acme/vless/private.key 2>/dev/null; then
        echo "  ✓ Сертификат выпущен (через $((i*5))s)"
        CERT_READY=true
        break
    fi
    sleep 5
    echo "  ... ещё ждём ($((i*5))s)"
done
if [ "$CERT_READY" = false ]; then
    echo "  ⚠ Сертификат не выпустился за 120 сек."
    echo "  Проверь:"
    echo "    1) DNS: A-запись ${DECOY_DOMAIN} должна указывать на IP этого сервера"
    echo "    2) Порт 80 открыт извне (для ACME-валидации)"
    echo "    3) Логи: docker logs angie"
    echo "  Скрипт продолжит, но xray не стартанёт пока серта нет."
fi
# --- Запуск Remnawave-node ---
echo ">>> Запуск Remnawave-node..."
docker compose up -d remnanode
# --- Админ-пользователь ---
echo ">>> Создание админ-пользователя ${ADMIN_USER}..."
if id "$ADMIN_USER" &>/dev/null; then
    echo "Пользователь ${ADMIN_USER} уже существует, пропускаем"
else
    useradd -m -s /bin/bash "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
    usermod -aG docker "$ADMIN_USER"
    passwd "$ADMIN_USER"
    mkdir -p /home/"$ADMIN_USER"/.ssh
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys /home/"$ADMIN_USER"/.ssh/authorized_keys
    fi
    chown -R "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh
    chmod 700 /home/"$ADMIN_USER"/.ssh
    chmod 600 /home/"$ADMIN_USER"/.ssh/authorized_keys 2>/dev/null || true
fi
# --- UFW ---
echo ">>> Настройка UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from ${PANEL_IP} to any port ${NODE_PORT} proto tcp
ufw --force enable
# --- SSH ---
echo ">>> Настройка SSH на порт ${SSH_PORT}..."
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/override.conf << EOFSSH
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOFSSH
systemctl daemon-reload
systemctl restart ssh.socket
cat > /etc/ssh/sshd_config.d/hardening.conf << EOFSSHD
PermitRootLogin no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOFSSHD
sshd -t && systemctl restart ssh || echo "ОШИБКА: sshd -t не прошёл! Не закрывай сессию!"
# --- Sysctl ---
echo ">>> Sysctl hardening..."
cat > /etc/sysctl.d/99-hardening.conf << EOFSYS
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOFSYS
sysctl --system
# --- Fail2Ban ---
echo ">>> Настройка Fail2Ban..."
apt install -y fail2ban
cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
EOF
systemctl enable fail2ban
systemctl restart fail2ban
# --- Генерация шаблонов конфигов ---
# Серверный xhttpSettings блок (зависит от метода)
case "$UPLINK_METHOD" in
    GET|HEAD|OPTIONS)
        SERVER_XHTTP_BLOCK=$(cat << EOFB
      "path": "${XHTTP_PATH}",
      "mode": "packet-up",
      "xPaddingObfsMode": true,
      "xPaddingMethod": "tokenish",
      "xPaddingPlacement": "queryInHeader",
      "xPaddingHeader": "X-Cache",
      "xPaddingKey": "_dc",
      "uplinkHTTPMethod": "${UPLINK_METHOD}",
      "uplinkDataPlacement": "header",
      "uplinkDataKey": "X-Payload",
      "uplinkChunkSize": 4096,
      "scMaxBufferedPosts": 30,
      "scMaxEachPostBytes": 1000000,
      "scMinPostsIntervalMs": 30,
      "xmux": {
        "cMaxReuseTimes": 256,
        "maxConcurrency": "16-32",
        "hMaxRequestTimes": 600,
        "hKeepAlivePeriod": 0
      }
EOFB
)
        CLIENT_EXTRA_BLOCK=$(cat << EOFC
  "xPaddingObfsMode": true,
  "xPaddingMethod": "tokenish",
  "xPaddingPlacement": "queryInHeader",
  "xPaddingHeader": "X-Cache",
  "xPaddingKey": "_dc",
  "uplinkHTTPMethod": "${UPLINK_METHOD}",
  "uplinkDataPlacement": "header",
  "uplinkDataKey": "X-Payload",
  "uplinkChunkSize": 4096,
  "xmux": {
    "cMaxReuseTimes": 256,
    "maxConcurrency": "16-32",
    "hMaxRequestTimes": 600,
    "hKeepAlivePeriod": 0
  }
EOFC
)
        ;;
    POST|PUT|PATCH)
        SERVER_XHTTP_BLOCK=$(cat << EOFB
      "path": "${XHTTP_PATH}",
      "mode": "packet-up",
      "xPaddingObfsMode": true,
      "xPaddingMethod": "tokenish",
      "xPaddingPlacement": "queryInHeader",
      "xPaddingHeader": "X-Cache",
      "xPaddingKey": "_dc",
      "uplinkHTTPMethod": "${UPLINK_METHOD}",
      "scMaxBufferedPosts": 30,
      "scMaxEachPostBytes": 1000000,
      "scMinPostsIntervalMs": 30,
      "xmux": {
        "cMaxReuseTimes": 256,
        "maxConcurrency": "16-32",
        "hMaxRequestTimes": 600,
        "hKeepAlivePeriod": 0
      }
EOFB
)
        CLIENT_EXTRA_BLOCK=$(cat << EOFC
  "xPaddingObfsMode": true,
  "xPaddingMethod": "tokenish",
  "xPaddingPlacement": "queryInHeader",
  "xPaddingHeader": "X-Cache",
  "xPaddingKey": "_dc",
  "uplinkHTTPMethod": "${UPLINK_METHOD}",
  "xmux": {
    "cMaxReuseTimes": 256,
    "maxConcurrency": "16-32",
    "hMaxRequestTimes": 600,
    "hKeepAlivePeriod": 0
  }
EOFC
)
        ;;
    *)
        echo "Неподдерживаемый метод: $UPLINK_METHOD"
        exit 1
        ;;
esac
# --- Сохранить шаблоны на диск ---
mkdir -p /opt/remnanode/templates
cat > /opt/remnanode/templates/inbound.json << EOFINB
{
  "tag": "XHTTP-CDN-${UPLINK_METHOD}",
  "port": 443,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "sniffing": {
    "enabled": true,
    "routeOnly": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["h2", "http/1.1"],
      "minVersion": "1.2",
      "certificates": [
        {
          "certificateFile": "/etc/angie-shared/acme/vless/certificate.pem",
          "keyFile": "/etc/angie-shared/acme/vless/private.key"
        }
      ]
    },
    "xhttpSettings": {
${SERVER_XHTTP_BLOCK}
    }
  }
}
EOFINB
cat > /opt/remnanode/templates/host-extra.json << EOFHE
{
${CLIENT_EXTRA_BLOCK}
}
EOFHE
# --- Итого ---
echo ""
echo "============================================"
echo "  УСТАНОВКА ЗАВЕРШЕНА"
echo "============================================"
echo "  SSH порт:        ${SSH_PORT}"
echo "  Node порт:       ${NODE_PORT}"
echo "  Decoy домен:     ${DECOY_DOMAIN}"
echo "  Панель IP:       ${PANEL_IP}"
echo "  Админ:           ${ADMIN_USER}"
echo "  Uplink Method:   ${UPLINK_METHOD}"
echo "  xHTTP Path:      ${XHTTP_PATH}"
echo "  CDN Domain:      ${CDN_DOMAIN}"
echo ""
echo "============================================"
echo "  ЧТО ДАЛЬШЕ"
echo "============================================"
echo ""
echo "  1. Открой НОВЫЙ терминал и проверь SSH под ${ADMIN_USER}:"
echo "     ssh ${ADMIN_USER}@<IP> -p ${SSH_PORT}"
echo "  НЕ закрывай текущую сессию пока не убедишься!"
echo ""
echo "  2. Проверь что нода поднялась:"
echo "     docker ps                  (должны быть angie + remnanode)"
echo "     docker logs remnanode --tail 20"
echo ""
echo "  3. В Remnawave-панели → Inbounds → Create:"
echo "     Используй шаблон: /opt/remnanode/templates/inbound.json"
echo "     (cat /opt/remnanode/templates/inbound.json)"
echo ""
echo "  4. В Remnawave-панели → Hosts → Create:"
echo "     Address: ${CDN_DOMAIN}"
echo "     Port: 443"
echo "     SNI: ${CDN_DOMAIN}"
echo "     Host: ${CDN_DOMAIN}"
echo "     Path: ${XHTTP_PATH}"
echo "     ALPN: h2,http/1.1"
echo "     Fingerprint: chrome"
echo "     В xHTTP settings (extra-блок) вставь содержимое:"
echo "     /opt/remnanode/templates/host-extra.json"
echo "     (cat /opt/remnanode/templates/host-extra.json)"
echo ""
echo "  5. В Beeline CDN UI (cdn.beeline.ru):"
echo "     - Создать ресурс HTTP-кеширования (тип «Статика»)"
echo "     - Источник: ${DECOY_DOMAIN}  (или IP этого сервера)"
echo "     - Кеширование: ОТКЛЮЧИТЬ полностью"
echo "     - Экспертные настройки:"
echo "         Gzip: ВЫКЛ"
echo "         Brotli: ВЫКЛ"
echo "         HTTP/3: ВЫКЛ"
echo "         HTTP/2: ВКЛ"
echo "         Только HTTPS: ВКЛ"
echo "         Только современные TLS: ВКЛ"
echo "         Поисковая индексация: ВЫКЛ"
echo "         Следовать редиректам: ВЫКЛ"
echo "         CORS на CDN: ВЫКЛ"
echo "         Таймауты: 60 / 3600 / 3600"
echo "         Разрешённые HTTP методы: + ${UPLINK_METHOD}"
echo "     - Сохранить → Полная очистка кэша"
echo ""
echo "  6. Проверка после настройки CDN:"
echo "     curl -kI https://${CDN_DOMAIN}${XHTTP_PATH}"
echo "     Должен вернуть HTTP/2 404 (с server: nginx, x-cdn-edge-id)"
echo ""
if [ "$CERT_READY" = false ]; then
    echo "  ⚠ ВНИМАНИЕ: ACME-сертификат не выпустился во время установки."
    echo "  Проверь логи angie и DNS A-запись для ${DECOY_DOMAIN}."
    echo "  После выпуска xray стартанёт автоматически (supervisord retry)."
    echo ""
fi
echo "  Шаблоны сохранены:"
echo "    /opt/remnanode/templates/inbound.json"
echo "    /opt/remnanode/templates/host-extra.json"
echo ""
echo "============================================"
