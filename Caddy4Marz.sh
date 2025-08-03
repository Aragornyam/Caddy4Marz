#!/usr/bin/env bash
set -euo pipefail

print_step() {
  echo -e "\n\e[1;34m▶ $1\e[0m"
}

print_done() {
  echo -e "\e[1;32m✔ Готово\e[0m\n"
}

fail() {
  echo -e "\e[1;31m✖ Ошибка:\e[0m $1"
  exit 1
}

safe_read() {
  local __resultvar=$1
  local prompt="$2"
  local default="$3"
  local validation="$4"
  local input=""
  local valid=0

  while [[ $valid -eq 0 ]]; do
    read -rp "$prompt" input || input=""
    input="${input:-$default}"

    if [[ -z "$validation" ]] || [[ "$input" =~ $validation ]]; then
      valid=1
    else
      echo -e "\e[1;31m✖ Некорректный ввод! Попробуйте снова.\e[0m"
    fi
  done

  printf -v "$__resultvar" '%s' "$input"
}

generate_random_string() {
  local length=${1:-16}
  (
    set +e
    tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c"$length"
    return 0
  ) || (
    date +%s | sha256sum | base64 | tr -dc 'A-Za-z0-9' | head -c"$length"
  ) || echo "rnd$(shuf -i 1000-9999 -n 1)"
}

[[ $EUID -ne 0 ]] && fail "Запустите скрипт от root, например: sudo $0"

echo -e "\e[1;35m
===========================================
 Установка и конфигурация Caddy для Marzban
===========================================
\e[0m"

print_step "1. Обновление системы и установка зависимостей"
apt update || fail "apt update завершился с ошибкой"
apt full-upgrade -y || fail "apt full-upgrade завершился с ошибкой"
print_done

print_step "2. Установка базовых зависимостей"
apt install -y curl gnupg apt-transport-https debian-keyring debian-archive-keyring \
  || fail "Не удалось установить базовые пакеты"
print_done

print_step "3. Установка Caddy"
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
  || fail "Ошибка загрузки GPG-ключа"

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null \
  || fail "Ошибка добавления репозитория"

chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list

apt update || fail "Ошибка обновления репозиториев"
apt install -y caddy || fail "Ошибка установки Caddy"
print_done

print_step "4. Подготовка файловой структуры"
mkdir -p /var/www/caddy /etc/caddy || fail "Не удалось создать директории"
echo "<h1>Работает Caddy для Marzban</h1>" > /var/www/caddy/index.html
print_done

print_step "5. Настройка параметров"
echo -e "\e[1;36m[Введите требуемые параметры для вашей установки]\e[0m"

while true; do
  safe_read DOMAIN "→ Доменное имя: " "" ""
  if [[ -z "$DOMAIN" ]]; then
    echo -e "\e[1;31m✖ Домен не может быть пустым!\e[0m"
  else
    break
  fi
done

safe_read USE_WWW "→ Использовать www-поддомен? [y/N]: " "n" "^[YyNn]?$"

DEFAULT_DASHBOARD_PATH=$(generate_random_string 12)
DEFAULT_XRAY_SUBSCRIPTION_PATH=$(generate_random_string 10)

safe_read DASHBOARD_PATH "→ Путь к панели (A-Z, a-z, 0-9, -_) [по умолчанию: $DEFAULT_DASHBOARD_PATH]: " \
  "$DEFAULT_DASHBOARD_PATH" "^[a-zA-Z0-9_-]+$"

safe_read XRAY_SUBSCRIPTION_PATH "→ Путь к подписке (A-Z, a-z, 0-9, -_) [по умолчанию: $DEFAULT_XRAY_SUBSCRIPTION_PATH]: " \
  "$DEFAULT_XRAY_SUBSCRIPTION_PATH" "^[a-zA-Z0-9_-]+$"

safe_read MARZBAN_PORT "→ Порт Marzban [8000-65535, по умолчанию: 8000]: " "8000" "^[0-9]+$"
safe_read HTTPS_PORT "→ HTTPS-порт Caddy [по умолчанию: 20000]: " "20000" "^[0-9]+$"

SERVER_IP=$(curl -s http://checkip.amazonaws.com || echo "127.0.0.1")
safe_read FINAL_IP "→ IP сервера [по умолчанию: $SERVER_IP]: " "$SERVER_IP" "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"

print_done

print_step "6. Генерация конфигурации Caddy"
cat > /etc/caddy/Caddyfile <<EOF
{
  https_port $HTTPS_PORT
  default_bind 127.0.0.1
  servers {
    listener_wrappers {
      proxy_protocol {
        allow 127.0.0.1/32
      }
      tls
    }
  }
  auto_https disable_redirects
}

https://$DOMAIN {
  @marzban expression path("/$DASHBOARD_PATH/*") || path("/$XRAY_SUBSCRIPTION_PATH/*") || path("/api/*") || path("/docs/*") || path("/redoc/*") || path("/openapi.json") || path("/statics/*")
  handle @marzban {
    reverse_proxy 127.0.0.1:$MARZBAN_PORT
  }
  header Alt-Svc h3=":443";ma=2592000
  root * /var/www/caddy
  file_server
  redir /index.html /
  log {
    output file /var/lib/caddy/access.log {
      roll_size 100mb
      roll_keep 5
    }
  }
}

https://$FINAL_IP {
  tls internal
  header Alt-Svc h3=":443";ma=2592000
  respond * 204
}

:80 {
  bind 0.0.0.0
  respond * 204
}

http://$DOMAIN$( [[ "$USE_WWW" =~ ^[Yy] ]] && echo ", http://www.$DOMAIN" ) {
  bind 0.0.0.0
  redir https://$DOMAIN{uri} permanent
}
EOF

if [[ "$USE_WWW" =~ ^[Yy] ]]; then
  cat >> /etc/caddy/Caddyfile <<EOF

https://www.$DOMAIN {
  header Alt-Svc h3=":443";ma=2592000
  redir https://$DOMAIN{uri} permanent
}
EOF
fi
print_done

print_step "7. Запуск сервиса Caddy"
systemctl enable caddy
systemctl restart caddy || fail "Не удалось перезапустить Caddy"
print_done

echo -e "\e[1;32m
===========================================
🎉 Установка успешно завершена!
===========================================\e[0m"

echo -e "\e[1;36m
Доступ к панели управления:
🔗 \e[1;34mhttps://$DOMAIN/$DASHBOARD_PATH/\e[0m

Ссылка для подписок:
🧾 \e[1;34mhttps://$DOMAIN/$XRAY_SUBSCRIPTION_PATH/\e[0m

📁 Файлы маскировочного сайта нужно класть в каталог: \e[1;34m/var/www/caddy\e[0m
\e[0m"

echo -e "\e[1;33m
⚠ ВАЖНО! Для окончательной настройки:
1. Откройте файл конфигурации Marzban:
   nano /opt/marzban/.env

2. Добавьте следующие параметры (пути должны быть в кавычках):
   DASHBOARD_PATH = \"/$DASHBOARD_PATH/\"
   XRAY_SUBSCRIPTION_PATH = \"$XRAY_SUBSCRIPTION_PATH\"

3. Перезапустите Marzban:
   marzban restart
\e[0m"