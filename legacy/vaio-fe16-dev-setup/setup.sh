#!/usr/bin/env bash
# Linux Mint 22.x (Ubuntu 24.04 base) — Ryzen 7 5825U developer workstation.
# Usage: bash setup.sh [--no-docker] [--no-earlyoom] [--skip-mise] [--check]
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WITH_DOCKER=1
WITH_EARLYOOM=1
WITH_MISE=1
CHECK_ONLY=0

usage() {
  cat <<'HELP'
Uso: bash setup.sh [opcoes]
  --no-docker      Nao instalar Docker/Compose
  --no-earlyoom    Nao instalar o protetor de memoria earlyoom
  --skip-mise      Nao instalar ou ativar o mise
  --check          Apenas diagnostico (nenhuma alteracao)
  -h, --help       Ajuda

Execute como usuario normal, NAO como root/sudo.
O script pedira sudo para instalacao e configuracao do sistema.
HELP
}
while (($#)); do
  case "$1" in
    --no-docker) WITH_DOCKER=0 ;;
    --no-earlyoom) WITH_EARLYOOM=0 ;;
    --skip-mise) WITH_MISE=0 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opcao desconhecida: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\n\033[1;34m[VAIO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

(( EUID != 0 )) || die 'Execute como usuario comum: bash setup.sh (o script solicita sudo quando preciso).'
[[ -r /etc/os-release ]] || die 'Nao foi possivel identificar o sistema.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "linuxmint" ]] || die "Este script foi feito para Linux Mint. Detectado: ${ID:-desconhecido}."
[[ "${UBUNTU_CODENAME:-}" == "noble" ]] || die "Necessaria base Ubuntu Noble (Linux Mint 22.x). Detectado: ${UBUNTU_CODENAME:-desconhecido}."
[[ "$(uname -m)" == "x86_64" ]] || die 'Necessaria arquitetura x86_64.'
[[ -d "$SCRIPT_DIR/bin" ]] || die 'Pasta bin/ ausente. Extraia o ZIP inteiro.'
command -v systemd-run >/dev/null || die 'systemd-run nao encontrado.'

log "Detectado: ${PRETTY_NAME:-Linux Mint} | CPU: $(awk -F: '/model name/{sub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo)"
if ! grep -qm1 'Ryzen 7 5825U' /proc/cpuinfo; then
  warn 'CPU diferente do Ryzen 7 5825U: os limites ainda sao conservadores, mas revise-os.'
fi

if ((CHECK_ONLY)); then
  exec bash "$SCRIPT_DIR/bin/dev-doctor"
fi

command -v sudo >/dev/null || die 'sudo nao encontrado.'
sudo -v || die 'Autenticacao sudo falhou.'

log 'Atualizando indices APT e instalando dependencias do desenvolvimento...'
sudo apt-get update
PACKAGES=(
  ca-certificates curl wget gnupg git git-lfs build-essential
  autoconf automake libtool cmake ninja-build pkg-config
  libssl-dev libffi-dev zlib1g-dev libbz2-dev libreadline-dev
  libsqlite3-dev liblzma-dev libncurses-dev libxml2-dev libpq-dev
  xz-utils unzip zip jq ripgrep fzf fd-find tree
  python3 python3-venv pipx
  htop btop sysstat lm-sensors mesa-utils mesa-vulkan-drivers vulkan-tools
  smartmontools nvme-cli powertop iotop
  zram-tools qemu-kvm cpu-checker
)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

BACKUP_BASE="/var/backups/vaio-fe16-dev-setup/$(date +%Y%m%d-%H%M%S)"
sudo install -d -m 0700 "$BACKUP_BASE"
backup_root() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  sudo cp -a -- "$file" "$BACKUP_BASE/$(basename "$file")"
}

log 'Configurando zram: LZ4, 50% da RAM logica, prioridade 100...'
ZRAM_CONF=/etc/default/zramswap
# Nao instalar dois gerenciadores concorrentes de zram.
if swapon --noheadings --raw --show=NAME 2>/dev/null | grep -q '^/dev/zram' \
  && ! systemctl is-active --quiet zramswap 2>/dev/null; then
  warn 'Outro gerenciador de zram esta ativo: configuracao de zram ignorada para evitar conflito.'
else
  backup_root "$ZRAM_CONF"
  if [[ ! -e "$ZRAM_CONF" ]]; then
    printf '' | sudo tee "$ZRAM_CONF" >/dev/null
  fi
  # Remove apenas as chaves que o script administra; preserva qualquer outra configuracao.
  sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*(ALGO|PERCENT|SIZE|PRIORITY)[[:space:]]*=/d' "$ZRAM_CONF"
  printf '\n# VAIO dev setup: tamanho LOGICO; nao reserva metade da RAM antecipadamente.\nALGO=lz4\nPERCENT=50\nPRIORITY=100\n' \
    | sudo tee -a "$ZRAM_CONF" >/dev/null
  if ! sudo systemctl restart zramswap; then
    warn 'zramswap nao iniciou. Veja: sudo journalctl -u zramswap -b --no-pager'
  fi
fi

log 'Definindo politicas conservadoras de memoria para zram...'
SYSCTL_FILE=/etc/sysctl.d/90-vaio-dev-zram.conf
backup_root "$SYSCTL_FILE"
printf '%s\n' '# VAIO developer workstation — prioriza zram antes de swap em disco.' \
  'vm.swappiness = 100' 'vm.page-cluster = 0' \
  | sudo tee "$SYSCTL_FILE" >/dev/null
sudo sysctl -p "$SYSCTL_FILE" >/dev/null

if ((WITH_EARLYOOM)); then
  if systemctl is-active --quiet systemd-oomd; then
    warn 'systemd-oomd ja esta ativo: earlyoom nao sera adicionado para evitar dois OOM daemons.'
  else
    log 'Ativando earlyoom como ultima protecao contra esgotamento de memoria...'
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom
    EARLYOOM_CONF=/etc/default/earlyoom
    backup_root "$EARLYOOM_CONF"
    sudo sed -i -E '/^[[:space:]]*EARLYOOM_ARGS=/d' "$EARLYOOM_CONF"
    # Evita processos essenciais do desktop. Sob pressao extrema o OOM pode encerrar apps.
    printf '%s\n' 'EARLYOOM_ARGS="-m 5 -s 5 --avoid ^(cinnamon|Xorg|Xwayland|systemd|sshd)$"' \
      | sudo tee -a "$EARLYOOM_CONF" >/dev/null
    sudo systemctl enable --now earlyoom
    sudo systemctl restart earlyoom
  fi
fi

log 'Preparando AMD-V/KVM para emulador Android...'
if grep -Eq '(^|[[:space:]])svm([[:space:]]|$)' /proc/cpuinfo; then
  sudo modprobe kvm_amd || warn 'kvm_amd nao carregou; verifique SVM/AMD-V no BIOS/UEFI.'
else
  warn 'SVM nao visivel no CPU: habilite AMD SVM/virtualizacao no BIOS/UEFI.'
fi
if getent group kvm >/dev/null; then
  if ! id -nG "$(id -un)" | grep -qw kvm; then
    sudo usermod -aG kvm "$(id -un)"
    warn 'Grupo kvm adicionado. Saia da sessao e entre novamente para aplicar.'
  fi
else
  warn 'Grupo kvm nao encontrado. Examine ls -l /dev/kvm depois da reinicializacao.'
fi

if ((WITH_DOCKER)); then
  log 'Instalando Docker e Compose dos repositorios da distribuicao...'
  if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    warn 'Docker CE ja esta instalado; nao misturarei os pacotes docker.io/Compose da distro.'
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
    sudo systemctl enable --now docker.service
  fi
  warn 'Por seguranca, usuario NAO foi adicionado automaticamente ao grupo docker (equivale a root). Use sudo docker ou configure rootless.'
fi

if ((WITH_MISE)); then
  log 'Configurando mise como gerenciador de linguagens (sem fixar versoes globais)...'
  if command -v mise >/dev/null 2>&1; then
    MISE_BIN="$(command -v mise)"
  elif [[ -x "$HOME/.local/bin/mise" ]]; then
    MISE_BIN="$HOME/.local/bin/mise"
  else
    INSTALLER="$(mktemp)"
    trap 'rm -f "${INSTALLER:-}"' EXIT
    curl --fail --show-error --location --silent https://mise.run -o "$INSTALLER"
    sh "$INSTALLER"
    rm -f "$INSTALLER"
    trap - EXIT
    MISE_BIN="$HOME/.local/bin/mise"
  fi
  [[ -x "$MISE_BIN" ]] || die 'mise nao encontrado apos instalacao.'
  mkdir -p "$HOME/.local/bin"
  # Evita misturar versoes entre ~/.local/bin e um pacote instalado por outro gerenciador.
  MISE_BIN="$(readlink -f "$MISE_BIN")"
  if ! grep -Fq 'mise activate bash' "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<ACTIVATION

# VAIO dev setup — mise (shell interativo)
if [[ \$- == *i* ]]; then
  eval "\$("$MISE_BIN" activate bash)"
fi
ACTIVATION
  fi
  if [[ -f "$HOME/.zshrc" ]] && ! grep -Fq 'mise activate zsh' "$HOME/.zshrc"; then
    cat >> "$HOME/.zshrc" <<ACTIVATION

# VAIO dev setup — mise
if [[ -o interactive ]]; then
  eval "\$("$MISE_BIN" activate zsh)"
fi
ACTIVATION
  fi
  "$MISE_BIN" --version
fi

log 'Configurando Gradle global para builds Android previsiveis...'
GRADLE_PROPS="$HOME/.gradle/gradle.properties"
mkdir -p "$(dirname "$GRADLE_PROPS")"
[[ -e "$GRADLE_PROPS" ]] && cp -a "$GRADLE_PROPS" "$GRADLE_PROPS.bak.$(date +%Y%m%d-%H%M%S)"
touch "$GRADLE_PROPS"
# Atualiza somente o bloco gerenciado; nao descarta personalizacoes fora dele.
sed -i '/^# BEGIN VAIO-DEV-SETUP$/,/^# END VAIO-DEV-SETUP$/d' "$GRADLE_PROPS"
cat >> "$GRADLE_PROPS" <<'GRADLE'

# BEGIN VAIO-DEV-SETUP
# RAM do heap do DAEMON; memoria total de compilacao pode ser maior.
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=768m -Dfile.encoding=UTF-8
org.gradle.workers.max=4
org.gradle.caching=true
org.gradle.parallel=true
org.gradle.daemon.idletimeout=900000
# END VAIO-DEV-SETUP
GRADLE

log 'Instalando wrappers seguros de build/emulador e diagnostico...'
install -d -m 0755 "$HOME/.local/bin"
for item in dev-run dev-build dev-emulator dev-doctor; do
  install -m 0755 "$SCRIPT_DIR/bin/$item" "$HOME/.local/bin/$item"
done
if ! grep -Fq 'VAIO dev setup PATH' "$HOME/.profile" 2>/dev/null; then
  cat >> "$HOME/.profile" <<'PROFILE'

# VAIO dev setup PATH
if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
  esac
  export PATH
fi
PROFILE
fi

log 'Instalacao concluida. Diagnostico:'
bash "$SCRIPT_DIR/bin/dev-doctor" || true
cat <<'FINAL'

PROXIMOS PASSOS:
  1. Reinicie ou encerre e reabra sua sessao (necessario para o grupo kvm).
  2. Instale Android Studio pelo pacote .tar.gz oficial e o SDK no Setup Wizard.
  3. Crie um AVD x86_64 no Device Manager (sugestao: 3 GB, 4 nucleos).
  4. Terminal novo: mise doctor
  5. Compilar: dev-build ./gradlew assembleDebug --no-daemon
  6. Emulador: dev-emulator --list ; dev-emulator NOME_DO_AVD
  7. Diagnostico: dev-doctor

IMPORTANTE: limites de memoria/CPU valem para comandos iniciados por dev-build
ou dev-emulator. O Android Studio, containers e builds disparados diretamente
pelo IDE precisam de configuracoes proprias; confira o README.
FINAL
