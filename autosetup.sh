#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------------
# Autosetup: Secure server auto-configuration script (Ubuntu/Debian)
# - Full APT update/upgrade with maintainer configs
# - Create sudo user with SSH key auth
# - Harden SSH: disable root login, change port, disable password auth
# - Scan and fix insecure SSH configs
# - Configure UFW firewall
# - Install and configure Fail2Ban
# - Logging to /var/log/autosetup.log and fail fast on errors
# ----------------------------------------------------------------------------

LOG_FILE="/var/log/autosetup.log"
DEBIAN_FRONTEND="noninteractive"
export DEBIAN_FRONTEND

# ----------------------------- Logging helpers -------------------------------
color_reset="\033[0m"; color_green="\033[32m"; color_yellow="\033[33m"; color_red="\033[31m"

log_ts() {
  date +"%Y-%m-%d %H:%M:%S%z"
}

log_info() {
  printf "[%s] [INFO] %s\n" "$(log_ts)" "$*" | tee -a "$LOG_FILE" >&2
}

log_warn() {
  printf "[%s] [WARN] %s\n" "$(log_ts)" "$*" | tee -a "$LOG_FILE" >&2
}

log_error() {
  printf "[%s] [ERROR] %s\n" "$(log_ts)" "$*" | tee -a "$LOG_FILE" >&2
}

# Ensure log file exists and is writable by root
init_logging() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" || true
}

# ----------------------------- Error handling --------------------------------

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-unknown}
  log_error "Скрипт прерван на строке ${line_no}. Код: ${exit_code}."
  exit "$exit_code"
}

trap on_error ERR

# ----------------------------- Preconditions ---------------------------------

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Этот скрипт должен быть запущен от root." >&2
    exit 1
  fi
}

require_commands() {
  local missing=()
  for cmd in bash sed grep awk cut sort shuf getent useradd usermod chpasswd chmod chown mkdir tee cp systemctl ss awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_warn "Будут установлены недостающие пакеты: ${missing[*]}"
  fi
}

# ----------------------------- Safe input ------------------------------------

prompt() { # $1 message; prints to stderr
  printf "%s" "$1" >&2
}

safe_read_line() { # $1 var_name, $2 prompt
  local __var_name="$1"
  local __prompt="$2"
  local __input=""
  while true; do
    prompt "$__prompt"
    IFS= read -r __input || true
    if [[ -n "$__input" ]]; then
      printf -v "$__var_name" '%s' "$__input"
      return 0
    fi
    log_warn "Пустой ввод. Повторите попытку."
  done
}

safe_read_silent_twice() { # $1 var_name, $2 prompt1, $3 prompt2, $4 min_len
  local __var_name="$1"; local __p1="$2"; local __p2="$3"; local __min_len="$4"
  local p1="" p2=""
  while true; do
    prompt "$__p1"
    IFS= read -rs p1 || true
    printf "\n" >&2
    prompt "$__p2"
    IFS= read -rs p2 || true
    printf "\n" >&2
    if [[ ${#p1} -lt $__min_len ]]; then
      log_warn "Пароль слишком короткий (мин. $__min_len символов)."
      continue
    fi
    if [[ "$p1" != "$p2" ]]; then
      log_warn "Пароли не совпадают. Повторите попытку."
      continue
    fi
    printf -v "$__var_name" '%s' "$p1"
    return 0
  done
}

ask_yes_no() { # $1 var_name, $2 prompt (expects 'y' or 'n')
  local __var_name="$1"; local __prompt="$2"
  local ans=""
  while true; do
    prompt "$__prompt [y/n]: "
    IFS= read -r ans || true
    case "${ans,,}" in
      y|yes) printf -v "$__var_name" 'y'; return 0 ;;
      n|no)  printf -v "$__var_name" 'n'; return 0 ;;
      *) log_warn "Введите 'y' или 'n'." ;;
    esac
  done
}

# ----------------------------- Validators ------------------------------------

validate_username() { # $1 username
  local u="$1"
  [[ ${#u} -ge 3 && ${#u} -le 16 ]] || return 1
  [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  return 0
}

username_exists() { getent passwd "$1" >/dev/null 2>&1; }

read_username() {
  local u=""
  while true; do
    safe_read_line u "Введите имя нового пользователя (3-16, латиница/цифры/_/-): "
    if ! validate_username "$u"; then
      log_warn "Недопустимое имя пользователя."
      continue
    fi
    if username_exists "$u"; then
      log_warn "Пользователь '$u' уже существует."
      continue
    fi
    USERNAME="$u"
    return 0
  done
}

read_password() {
  local p
  safe_read_silent_twice p "Введите пароль для $USERNAME: " "Повторите пароль: " 8
  PASSWORD="$p"
}

validate_ssh_key() { # $1 key
  local k="$1"
  # Basic format: <type> <base64> <comment>
  if [[ ${#k} -lt 372 ]]; then return 1; fi
  if ! echo "$k" | awk 'NF<3 {exit 1}'; then return 1; fi
  if ! [[ "$k" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+\ .+$ ]]; then
    return 1
  fi
  return 0
}

read_ssh_key() {
  local key
  while true; do
    safe_read_line key "Вставьте SSH публичный ключ одной строкой: "
    if validate_ssh_key "$key"; then
      SSH_PUBKEY="$key"
      return 0
    fi
    log_warn "Ключ не прошёл проверку формата. Убедитесь, что он начинается с ssh-rsa/ssh-ed25519/ecdsa-sha2-nistp*, содержит base64 и комментарий, и длина >= 372."
  done
}

# ----------------------------- Networking utils ------------------------------

is_command() { command -v "$1" >/dev/null 2>&1; }

is_port_in_use_any() { # $1 port
  local p="$1"
  if is_command ss; then
    ss -ltn | awk '{print $4}' | awk -F: 'NF{print $NF}' | grep -xq "$p" && return 0 || return 1
  elif is_command netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | awk -F: 'NF{print $NF}' | grep -xq "$p" && return 0 || return 1
  else
    log_warn "Ни ss, ни netstat не найдены. Пропускаю проверку порта."
    return 1
  fi
}

sshd_active_ports() {
  if is_command ss; then
    ss -ltnp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: 'NF{print $NF}' | sort -u
  elif is_command netstat; then
    netstat -ltnp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: 'NF{print $NF}' | sort -u
  else
    return 0
  fi
}

is_port_in_sshd_active() { # $1 port
  local p="$1"
  sshd_active_ports | grep -xq "$p"
}

find_free_port() {
  local candidate
  local attempts=0
  while (( attempts < 200 )); do
    candidate=$(shuf -i 1024-65535 -n 1)
    if ! is_port_in_use_any "$candidate" && ! is_port_in_sshd_active "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    attempts=$((attempts+1))
  done
  # Fallback: return 22222 even if in use (validated later)
  printf '22222'
  return 0
}

read_port() {
  local suggested="$1"
  local ans=""
  prompt "Предложенный SSH-порт: $suggested. Использовать его? [Y/n]: "
  IFS= read -r ans || true
  if [[ -z "${ans:-}" || ${ans,,} == y || ${ans,,} == yes ]]; then
    CHOSEN_PORT="$suggested"
    return 0
  fi
  local p
  while true; do
    safe_read_line p "Введите свой порт (1024-65535): "
    if ! [[ "$p" =~ ^[0-9]+$ ]]; then
      log_warn "Порт должен быть числом."
      continue
    fi
    if (( p < 1024 || p > 65535 )); then
      log_warn "Порт вне диапазона."
      continue
    fi
    if is_port_in_use_any "$p"; then
      log_warn "Порт $p уже занят."
      continue
    fi
    if is_port_in_sshd_active "$p"; then
      log_warn "Порт $p уже используется sshd."
      continue
    fi
    CHOSEN_PORT="$p"
    return 0
  done
}

# ----------------------------- File helpers ----------------------------------

backup_file() { # $1 filepath
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

safe_edit_config() { # $1 file, $2 directive, $3 value
  local file="$1" key="$2" val="$3"
  [[ -f "$file" ]] || touch "$file"
  backup_file "$file"
  if grep -qiE "^\s*#?\s*${key}\b" "$file"; then
    sed -i -E "s|^\s*#?\s*(${key})\b.*|\\1 ${val}|I" "$file"
  else
    printf "%s %s\n" "$key" "$val" >>"$file"
  fi
}

# ----------------------------- APT operations --------------------------------

apt_update_upgrade() {
  log_info "Обновление списков пакетов..."
  apt-get update -y
  log_info "Обновление установленных пакетов (с версиями мейнтейнера для конфигов)..."
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew upgrade
}

apt_install() { # packages...
  local pkgs=("$@")
  if (( ${#pkgs[@]} > 0 )); then
    log_info "Установка пакетов: ${pkgs[*]}"
    apt-get install -y "${pkgs[@]}"
  fi
}

# ----------------------------- SSH config ------------------------------------

apply_sshd_hardening() {
  local port="$1"
  local sshd_cfg="/etc/ssh/sshd_config"

  log_info "Применение жёстких настроек SSH..."
  backup_file "$sshd_cfg"

  # Ensure critical options
  safe_edit_config "$sshd_cfg" Port "$port"
  safe_edit_config "$sshd_cfg" PermitRootLogin "no"
  safe_edit_config "$sshd_cfg" PasswordAuthentication "no"
  safe_edit_config "$sshd_cfg" ChallengeResponseAuthentication "no"
  safe_edit_config "$sshd_cfg" UsePAM "yes"

  # Remove duplicate Port lines leaving the last one
  awk 'BEGIN{IGNORECASE=1} {if ($1 ~ /^#?port$/) last=NR} {lines[NR]=$0} END{for(i=1;i<=NR;i++){if(i==last) print lines[i]; else if(lines[i] ~ /^[#[:space:]]*port[[:space:]].*$/) next; else print lines[i]}}' "$sshd_cfg" >"${sshd_cfg}.tmp"
  mv "${sshd_cfg}.tmp" "$sshd_cfg"

  # Validate configuration
  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  elif command -v /usr/sbin/sshd >/dev/null 2>&1; then
    /usr/sbin/sshd -t
  fi

  # Restart service
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    log_info "Перезапуск службы ssh..."
    systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    log_info "Перезапуск службы sshd..."
    systemctl restart sshd
  else
    log_warn "Служба SSH не найдена через systemctl. Пытаюсь запустить service ssh restart."
    service ssh restart || service sshd restart || true
  fi
}

scan_and_fix_insecure_ssh() {
  log_info "Сканирование /etc/ssh на предмет PasswordAuthentication yes..."
  local files
  mapfile -t files < <(grep -RIl --exclude-dir="*.bak*" -E "^[[:space:]]*PasswordAuthentication[[:space:]]+yes" /etc/ssh || true)
  if (( ${#files[@]} == 0 )); then
    log_info "Опасные конфигурации не найдены."
    return 0
  fi
  for f in "${files[@]}"; do
    log_warn "Исправление: $f"
    backup_file "$f"
    sed -i -E 's|^([[:space:]]*PasswordAuthentication[[:space:]]+)yes|\1no|g' "$f"
  done
}

# ----------------------------- User/SSH key ----------------------------------

create_user_and_key() {
  local username="$1" password="$2" pubkey="$3"
  log_info "Создание пользователя $username и добавление в sudo..."
  useradd -m -s /bin/bash "$username"
  echo "$username:$password" | chpasswd
  usermod -aG sudo "$username"

  local ssh_dir="/home/$username/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  printf "%s\n" "$pubkey" > "$auth_keys"
  chmod 600 "$auth_keys"
  chown -R "$username:$username" "$ssh_dir"
  log_info "SSH ключ добавлен в $auth_keys"
}

# ----------------------------- UFW -------------------------------------------

configure_ufw() {
  local ssh_port="$1"
  log_info "Установка и настройка UFW..."
  apt_install ufw
  ufw --force reset || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$ssh_port"/tcp comment "SSH"

  local open443="n"
  ask_yes_no open443 "Открыть порт 443 (HTTPS)?"
  if [[ "$open443" == "y" ]]; then
    ufw allow 443/tcp comment "HTTPS"
  fi
  echo "y" | ufw enable
  ufw status verbose | tee -a "$LOG_FILE" >&2
}

# ----------------------------- Fail2Ban --------------------------------------

configure_fail2ban() {
  local ssh_port="$1"
  log_info "Установка и настройка Fail2Ban..."
  apt_install fail2ban
  local jail_local="/etc/fail2ban/jail.local"
  backup_file "$jail_local"
  cat > "$jail_local" <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${ssh_port}
logpath = /var/log/auth.log
backend = systemd
EOF
  systemctl restart fail2ban || true
  systemctl enable fail2ban || true
}

# ----------------------------- Summary ---------------------------------------

print_summary() {
  local port="$1" user="$2"
  cat <<EOM
Готово!
SSH-порт: ${port}
Вход по ключу: включен
Вход по паролю: отключён
Пользователь: ${user}

Для повторного запуска: bash autosetup.sh
EOM
}

# ----------------------------- Main ------------------------------------------

main() {
  require_root
  init_logging

  log_info "Сценарий автоконфигурации сервера. Выполняются операции, влияющие на сеть и доступ по SSH."
  local answer=""
  prompt "Вы готовы приступить? (agree/exit): "
  IFS= read -r answer || true
  case "${answer,,}" in
    agree) : ;;
    *) log_info "Завершение по запросу пользователя."; exit 0 ;;
  esac

  require_commands

  apt_update_upgrade

  read_username
  read_password
  read_ssh_key

  create_user_and_key "$USERNAME" "$PASSWORD" "$SSH_PUBKEY"

  local suggested_port
  suggested_port=$(find_free_port)
  read_port "$suggested_port"

  apply_sshd_hardening "$CHOSEN_PORT"

  scan_and_fix_insecure_ssh

  # Show summary so far before firewall changes
  log_info "Базовая настройка SSH завершена."
  print_summary "$CHOSEN_PORT" "$USERNAME"

  configure_ufw "$CHOSEN_PORT"

  configure_fail2ban "$CHOSEN_PORT"

  log_info "Все операции завершены успешно."
  print_summary "$CHOSEN_PORT" "$USERNAME"
}

# Globals populated by readers
USERNAME=""
PASSWORD=""
SSH_PUBKEY=""
CHOSEN_PORT=""

main "$@"