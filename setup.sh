#!/bin/bash
set -e

# ---------- Установка Docker (если отсутствует) ----------
if ! command -v docker &> /dev/null; then
    echo "Docker не найден. Устанавливаю..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
fi

if ! docker compose version &> /dev/null; then
    echo "Устанавливаю плагин docker compose..."
    apt-get update && apt-get install -y docker-compose-plugin
fi

# ---------- Клонирование репозитория, если запускаем не из него ----------
if [ ! -f "docker-compose.yml" ]; then
    git clone https://github.com/vmhlov/naive-proxy.git /opt/naive-proxy
    cd /opt/naive-proxy
fi

# ---------- Запрос параметров (если не переданы) ----------
if [ -z "$DOMAIN" ]; then
    read -p "Введите ваш публичный IP: " IP
    DOMAIN="${IP}.nip.io"
fi

if [ -z "$EMAIL" ]; then
    EMAIL="aaa@aa.com"
fi

if [ -z "$PROXY_USER" ]; then
    read -p "Логин для прокси: " PROXY_USER
fi

if [ -z "$PROXY_PASS" ]; then
    read -sp "Пароль для прокси: " PROXY_PASS
    echo
fi

# ---------- Генерация .env ----------
cat > .env <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
PROXY_USER=${PROXY_USER}
PROXY_PASS=${PROXY_PASS}
TZ=Europe/Moscow
EOF

# ---------- Запуск ----------
docker compose up -d
echo ""
echo "Готово! Сервер запущен."
echo "Ваша ссылка для подключения:"
echo "naive+quic://${PROXY_USER}:${PROXY_PASS}@${DOMAIN}:443?padding=true#Naive"
