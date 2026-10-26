
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Arch Minimal Setup
# Pantheon + LightDM + rede + Bluetooth + apps
# Execute como usuario normal.

VERSION="2.0"
LOG="$HOME/arch-postinstall.log"
AUR_HELPER="yay"

exec > >(tee -a "$LOG") 2>&1
trap 'echo; echo "ERRO na linha $LINENO. Consulte $LOG"' ERR

info() { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }
die()  { echo "[ERRO] $*" >&2; exit 1; }

confirmar() {
    local resposta
    read -r -p "$1 [s/N] " resposta
    [[ "$resposta" =~ ^[sS]$ ]]
}

command -v pacman >/dev/null || die "pacman nao encontrado."
[[ -f /etc/arch-release ]] || die "Este script exige Arch Linux."
[[ "$EUID" -ne 0 ]] || die "Execute como usuario normal, nao como root."

command -v sudo >/dev/null || die "Instale sudo primeiro."
sudo -v

info "Arch Minimal Setup v$VERSION"
info "Log: $LOG"

if ! ping -c 1 -W 3 archlinux.org >/dev/null 2>&1; then
    warn "Nao foi possivel testar a conexao com archlinux.org."
    warn "Confirme que a rede e o DNS funcionam."
    confirmar "Tentar continuar mesmo assim?" || exit 1
fi

confirmar "Deseja iniciar a pos-instalacao?" || exit 0

# Evita executar duas instancias ao mesmo tempo.
exec 9>"$HOME/.arch-postinstall.lock"
flock -n 9 || die "Ja existe outra instancia em execucao."

info "Atualizando o sistema."
sudo pacman -Syu --needed

# Ferramentas essenciais.
sudo pacman -S --needed \
    git base-devel curl pciutils usbutils \
    iproute2 wireless-regdb

# Localiza pacote no repositorio oficial.
oficial() {
    pacman -Si "$1" >/dev/null 2>&1
}

# Instala yay somente se um pacote realmente precisar do AUR.
instalar_yay() {
    command -v yay >/dev/null 2>&1 && return 0

    warn "O yay sera compilado a partir do AUR."
    confirmar "Deseja instalar o yay?" || return 1

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"; echo "Erro na linha $LINENO. Consulte $LOG"' ERR

    git clone https://aur.archlinux.org/yay.git "$tmp/yay"
    (
        cd "$tmp/yay"
        makepkg -si
    )

    rm -rf "$tmp"
    command -v yay >/dev/null
}

# Oficial primeiro. AUR somente com consentimento.
instalar_pacote() {
    local pacote="$1"

    if pacman -Q "$pacote" >/dev/null 2>&1; then
        ok "$pacote ja esta instalado."
        return 0
    fi

    if oficial "$pacote"; then
        info "Repositorio oficial: $pacote"
        sudo pacman -S --needed "$pacote"
        return
    fi

    warn "$pacote nao encontrado nos repositorios oficiais."
    warn "O AUR nao e um repositorio oficial: revise a receita antes de instalar."

    confirmar "Pesquisar/instalar $pacote no AUR?" || {
        warn "Ignorado: $pacote"
        return 0
    }

    instalar_yay || {
        warn "Nao foi possivel preparar o yay."
        return 0
    }

    # -S mostra o fluxo de revisao do yay; nao usa --noconfirm.
    yay -S --needed "$pacote"
}

instalar_lista() {
    local pacote
    for pacote in "$@"; do
        instalar_pacote "$pacote"
    done
}

# -----------------------------
# Rede e hardware
# -----------------------------

info "Instalando rede e firmware."
instalar_lista \
    networkmanager \
    linux-firmware \
    bluez \
    bluez-utils \
    accountsservice \
    xdg-user-dirs

# NetworkManager controla Ethernet e Wi-Fi.
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now bluetooth

info "Interfaces detectadas:"
ip -brief link || true

# -----------------------------
# Audio
# -----------------------------

info "Instalando audio."
instalar_lista \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber

# PipeWire normalmente e iniciado pela sessao do usuario.
# Nao habilitamos servicos globais de audio.

# -----------------------------
# Detectar GPU
# -----------------------------

info "GPU detectada:"
lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true

GPU="$(lspci 2>/dev/null | grep -Ei \
    'VGA compatible controller|3D controller|Display controller' || true)"

echo
echo "Escolha a configuracao grafica:"
echo "1) Intel"
echo "2) AMD"
echo "3) NVIDIA"
echo "4) Graficos genericos / maquina virtual"
echo "5) Somente Mesa; decidir depois"
echo

read -r -p "Opcao [1-5]: " VIDEO

case "$VIDEO" in
    1)
        instalar_lista mesa vulkan-intel intel-media-driver
        ;;
    2)
        instalar_lista mesa vulkan-radeon libva-mesa-driver
        ;;
    3)
        echo "$GPU"
        echo
        warn "A NVIDIA exige compatibilidade entre GPU, driver e kernel."
        echo "Confira o modelo e a tabela oficial de suporte."
        echo "1) NVIDIA open para GPU compativel e kernel linux"
        echo "2) NVIDIA open DKMS (kernel compativel + headers)"
        echo "3) Pular driver NVIDIA"
        read -r -p "Opcao [1-3]: " NV

        case "$NV" in
            1)
                confirmar "Confirma compatibilidade da GPU?" &&
                    instalar_lista nvidia-open nvidia-utils
                ;;
            2)
                instalar_lista dkms
                case "$(uname -r)" in
                    *-lts)
                        instalar_lista linux-lts-headers
                        ;;
                    *)
                        instalar_lista linux-headers
                        ;;
                esac
                instalar_lista nvidia-open-dkms nvidia-utils
                ;;
            *)
                warn "Driver NVIDIA ignorado."
                ;;
        esac
        ;;
    4|5)
        instalar_lista mesa
        ;;
    *)
        warn "Opcao invalida. Instalando apenas Mesa."
        instalar_lista mesa
        ;;
esac

# -----------------------------
# Pantheon
# -----------------------------

info "Instalando componentes do Pantheon."
instalar_lista \
    xorg-server \
    mesa \
    pantheon-session \
    gala \
    wingpanel \
    plank \
    pantheon-settings-daemon \
    switchboard \
    elementary-icon-theme \
    gtk-theme-elementary \
    elementary-wallpapers \
    lightdm \
    accountsservice

# Alguns nomes variam entre versoes/distribuicoes.
# Estes componentes sao opcionais.
echo
confirmar "Instalar o menu de aplicativos do Pantheon?" &&
    instalar_pacote pantheon-applications-menu || true

confirmar "Instalar as configuracoes padrao do Pantheon?" &&
    instalar_pacote pantheon-default-settings || true

# -----------------------------
# Escolha do greeter
# -----------------------------

echo
echo "Escolha a tela de login:"
echo "1) Pantheon Greeter"
echo "2) Slick Greeter (visual configuravel)"
echo "3) Nao alterar greeter"
read -r -p "Opcao [1-3]: " GREETER

case "$GREETER" in
    1)
        instalar_pacote lightdm-pantheon-greeter
        ;;
    2)
        instalar_pacote slick-greeter
        ;;
    *)
        GREETER=3
        warn "Greeter nao sera alterado."
        ;;
esac

# Configura somente quando o greeter solicitado estiver instalado.
if [[ "$GREETER" == "1" ]]; then
    GREETER_FILE="$(find /usr/share/xgreeters -maxdepth 1 \
        -type f -iname '*elementary*.desktop' -print -quit 2>/dev/null || true)"

    if [[ -n "$GREETER_FILE" ]]; then
        GREETER_ID="$(basename "$GREETER_FILE" .desktop)"
        sudo install -d /etc/lightdm/lightdm.conf.d
        sudo tee /etc/lightdm/lightdm.conf.d/50-postinstall.conf >/dev/null <<EOF
[Seat:*]
greeter-session=$GREETER_ID
EOF
        ok "Greeter configurado: $GREETER_ID"
    else
        warn "Desktop entry do Pantheon Greeter nao encontrado."
        warn "LightDM nao sera reconfigurado automaticamente."
    fi
elif [[ "$GREETER" == "2" ]]; then
    if [[ -f /usr/share/xgreeters/slick-greeter.desktop ]]; then
        sudo install -d /etc/lightdm/lightdm.conf.d
        sudo tee /etc/lightdm/lightdm.conf.d/50-postinstall.conf >/dev/null <<'EOF'
[Seat:*]
greeter-session=slick-greeter
EOF
        info "Slick Greeter selecionado."
        info "Configure o fundo em /etc/lightdm/slick-greeter.conf."
    else
        warn "Entrada do Slick Greeter nao encontrada; configuracao ignorada."
    fi
fi

# -----------------------------
# Aplicativos
# -----------------------------

info "Instalando aplicativos."
instalar_lista firefox qbittorrent

confirmar "Instalar o iniciador do Tor Browser?" &&
    instalar_pacote torbrowser-launcher || true

# -----------------------------
# Papel de parede e usuario
# -----------------------------

xdg-user-dirs-update

echo
info "Papeis de parede disponiveis:"
find /usr/share/backgrounds /usr/share/wallpapers \
    -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' \) \
    -print 2>/dev/null | head -30 || true

echo
warn "O papel de parede da sessao depende das ferramentas da sessao Pantheon."
warn "O papel de parede do greeter e configurado separadamente."
warn "Nao alteramos arquivos pessoais nem presumimos um caminho de imagem."

# -----------------------------
# Validacao final
# -----------------------------

echo
info "Estado da rede:"
nmcli device status || true

echo
info "Bluetooth:"
systemctl is-enabled bluetooth || true
systemctl is-active bluetooth || true

echo
info "Sessoes graficas:"
ls -1 /usr/share/xsessions /usr/share/wayland-sessions 2>/dev/null || true

echo
info "Greeters disponiveis:"
ls -1 /usr/share/xgreeters 2>/dev/null || true

echo
info "Servicos:"
systemctl is-enabled NetworkManager || true
systemctl is-active NetworkManager || true

echo
ok "Processo concluido."
echo "Log: $LOG"
echo "Revise os avisos antes de reiniciar."
echo
confirmar "Deseja habilitar o LightDM para o proximo boot?" &&
    sudo systemctl enable lightdm || true

echo
echo "Para reiniciar manualmente: sudo reboot"
