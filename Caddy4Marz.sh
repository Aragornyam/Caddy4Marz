#!/usr/bin/env bash
set -euo pipefail

SERVER_IP=$(curl -s4 https://checkip.amazonaws.com || curl -s4 https://ifconfig.me || echo "127.0.0.1")

print_step() {
  echo -e "\n\e[1;34m▶ $1\e[0m"
}

print_done() {
  echo -e "\e[1;32m✔ Готово\e[0m"
}

print_warning() {
  echo -e "\e[1;33m⚠ ВНИМАНИЕ: $1\e[0m"
}

fail() {
  echo -e "\n\e[1;31m✖ ОШИБКА:\e[0m $1" >&2
  exit 1
}

safe_read() {
  local __resultvar=$1
  local prompt="$2"
  local default="$3"
  local validation_regex="$4"
  local input=""
  local valid=0

  while [[ $valid -eq 0 ]]; do
    read -rp "$prompt" input || true
    input="${input:-$default}"

    if [[ -z "$validation_regex" ]] || [[ "$input" =~ $validation_regex ]]; then
      valid=1
    else
      echo -e "\e[1;31m  ✖ Некорректный ввод. Попробуйте снова.\e[0m"
    fi
  done
  printf -v "$__resultvar" '%s' "$input"
}

generate_random_string() {
    (
        set +o pipefail
        tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${1:-12}"
    )
}

prepare_system() {
  print_step "1. Обновление системы и установка зависимостей"
  apt-get update -y || fail "Не удалось обновить список пакетов (apt-get update)."
  apt-get full-upgrade -y || fail "Не удалось обновить пакеты (apt-get full-upgrade)."
  apt-get install -y --no-install-recommends curl gnupg apt-transport-https debian-keyring debian-archive-keyring dnsutils \
    || fail "Не удалось установить базовые зависимости."
  print_done
}

install_caddy() {
  print_step "2. Установка веб-сервера Caddy"
  if command -v caddy &>/dev/null; then
    print_warning "Caddy уже установлен. Обновляю до последней версии..."
    apt-get install --only-upgrade -y caddy
  else
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
      || fail "Не удалось загрузить GPG-ключ для Caddy."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null \
      || fail "Не удалось добавить репозиторий Caddy."
    apt-get update -y || fail "Не удалось обновить список пакетов после добавления репозитория Caddy."
    apt-get install -y caddy || fail "Не удалось установить Caddy."
  fi
  print_done
}

get_user_settings() {
  print_step "3. Настройка параметров"

  while true; do
    safe_read DOMAIN "→ Введите доменное имя: " "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    echo "  Проверяю домен '$DOMAIN'..."
    DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1)

    if [[ -z "$DOMAIN_IP" ]]; then
      print_warning "Не удалось определить IP-адрес для домена '$DOMAIN'. Убедитесь, что A-запись существует."
      continue
    fi

    echo "  ✔ Домен '$DOMAIN' указывает на IP: $DOMAIN_IP"
    echo "  → IP-адрес этого сервера: $SERVER_IP"

    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
      print_warning "IP домена ($DOMAIN_IP) не совпадает с IP сервера ($SERVER_IP)!"
      safe_read continue_anyway "→ Caddy может не получить SSL-сертификат. Все равно продолжить? [y/N]: " "n" "^[YyNn]?$"
      if [[ "$continue_anyway" =~ ^[Yy]$ ]]; then
        break
      fi
    else
      echo -e "\e[1;32m  ✔ Отлично! IP домена совпадает с IP сервера.\e[0m"
      break
    fi
  done

  safe_read USE_WWW "→ Использовать www-поддомен (www.$DOMAIN)? [y/N]: " "n" "^[YyNn]?$"
  DEFAULT_DASHBOARD_PATH=$(generate_random_string 12)
  safe_read DASHBOARD_PATH "→ Путь к админ-панели (по умолчанию: $DEFAULT_DASHBOARD_PATH): " "$DEFAULT_DASHBOARD_PATH" "^[a-zA-Z0-9_-]+$"
  DEFAULT_SUB_PATH=$(generate_random_string 10)
  safe_read XRAY_SUBSCRIPTION_PATH "→ Путь для ссылок-подписок (по умолчанию: $DEFAULT_SUB_PATH): " "$DEFAULT_SUB_PATH" "^[a-zA-Z0-9_-]+$"
  safe_read MARZBAN_PORT "→ Порт Marzban (по умолчанию: 8000): " "8000" "^([1-9][0-9]{3,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
  safe_read HTTPS_PORT "→ Внешний HTTPS-порт Caddy (по умолчанию: 20000): " "20000" "^([1-9][0-9]{0,4})$"
  safe_read FINAL_IP "→ IP сервера для привязки (по умолчанию: $SERVER_IP): " "$SERVER_IP" "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"

  print_done
}

generate_caddy_config() {
  print_step "4. Создание конфигурации для Caddy"

  local caddyfile_path="/etc/caddy/Caddyfile"
  if [[ -f "$caddyfile_path" ]]; then
      print_warning "Файл '$caddyfile_path' уже существует."
      safe_read overwrite "→ Перезаписать его? [y/N]: " "n" "^[YyNn]?$"
      if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
          echo "  Пропускаю создание конфигурации."
          return
      fi
      echo "  Создаю резервную копию в ${caddyfile_path}.bak..."
      cp "$caddyfile_path" "${caddyfile_path}.bak"
  fi

  mkdir -p /var/www/caddy /etc/caddy /var/log/caddy
  echo "<h1>Caddy for Marzban is working!</h1>" > /var/www/caddy/index.html
  chown -R caddy:caddy /var/www/caddy /etc/caddy /var/log/caddy

  cat > "$caddyfile_path" <<EOF
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
  header Alt-Svc h3=":$HTTPS_PORT";ma=2592000
  root * /var/www/caddy
  file_server
  redir /index.html /
  log {
    output file /var/log/caddy/access.log {
      roll_size 100mb
      roll_keep 5
    }
  }
}

https://$FINAL_IP {
  tls internal
  header Alt-Svc h3=":$HTTPS_PORT";ma=2592000
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

  if [[ "$USE_WWW" =~ ^[Yy]$ ]]; then
    cat >> "$caddyfile_path" <<EOF

https://www.$DOMAIN {
  header Alt-Svc h3=":$HTTPS_PORT";ma=2592000
  redir https://$DOMAIN{uri} permanent
}
EOF
  fi
  print_done
}

start_caddy_service() {
  print_step "5. Запуск и активация сервиса Caddy"

  echo "  Форматирую и проверяю конфигурацию..."
  caddy fmt --overwrite /etc/caddy/Caddyfile || print_warning "Не удалось автоматически отформатировать Caddyfile."
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || fail "Конфигурация Caddy не прошла проверку. Исправьте ошибки в /etc/caddy/Caddyfile."

  echo "  Активирую и перезапускаю сервис Caddy..."
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy || fail "Не удалось запустить/перезапустить сервис Caddy."
  print_done
}

show_final_summary() {
  echo -e "\e[1;32m
===========================================
🎉 Установка успешно завершена!
===========================================\e[0m"

  echo -e "\e[1;36m
Админ-панель Marzban доступна по адресу:
🔗 \e[1;34mhttps://$DOMAIN/$DASHBOARD_PATH/\e[0m

Ссылка для импорта подписок в клиенты:
🧾 \e[1;34mhttps://$DOMAIN/$XRAY_SUBSCRIPTION_PATH/{token}\e[0m

📁 Файлы для сайта-заглушки находятся в каталоге: \e[1;34m/var/www/caddy\e[0m
\e[0m"

  echo -e "\e[1;33m
⚠ ВАЖНО! Остался последний шаг — настройка Marzban:
1. Откройте файл конфигурации Marzban:
   \e[0;33mnano /opt/marzban/.env\e[0m

2. Добавьте или измените в нем следующие строки:
   \e[0;33mDASHBOARD_PATH = \"/$DASHBOARD_PATH/\" \e[0m
   \e[0;33mXRAY_SUBSCRIPTION_PATH = \"$XRAY_SUBSCRIPTION_PATH\" \e[0m

3. Перезапустите Marzban, чтобы применить изменения:
   \e[0;33mmarzban restart\e[0m
\e[0m"
}

main() {
  [[ $EUID -ne 0 ]] && fail "Запустите скрипт с правами root, например: sudo $0"

  echo -e "\e[1;35m
===========================================
  Установка и конфигурация Caddy для Marzban
===========================================
\e[0m"

  prepare_system
  install_caddy
  get_user_settings
  generate_caddy_config
  start_caddy_service
  show_final_summary
}

main "$@"