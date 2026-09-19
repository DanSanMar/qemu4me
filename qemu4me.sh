#!/usr/bin/env bash

# ==============================================================================
#  qemu4me - Gestor ultraligero de VMs para Pentesting (QEMU Nativo)
#  Auditoría & Hardening: DevSecOps Standard (Soporte Bridge Aislado / Wi-Fi)
# ==============================================================================

set -uo pipefail          # Quitamos -e global: una VM que falla no debe matar el manager
shopt -s nullglob

CONFIG_DIR="$HOME/.config/qemu4me"
VM_STORAGE_DIR="$CONFIG_DIR/disks"
VM_CONFIG_DIR="$CONFIG_DIR/vms"
QMP_DIR="$CONFIG_DIR/qmp"
PID_DIR="$CONFIG_DIR/pids"
CAPTURE_DIR="$CONFIG_DIR/captures"

TMP_OVA_DIR=""

# ==============================================================================
# Variables de Color y Estado
# ==============================================================================
RESET="\e[0m"
BLANCO="\e[97m"
BLANCO_NEGRITA="\e[1;37m"
GRIS_CLARO="\e[37m"
AZUL_OSCURO="\e[34m"
AZUL_BRILLANTE="\e[1;34m"
AZUL_CLARO="\e[94m"
VERDE="\e[32m"
VERDE_BRILLANTE="\e[1;32m"
AMARILLO="\e[33m"
AMARILLO_BRILLANTE="\e[1;33m"
CIAN="\e[36m"
CIAN_BRILLANTE="\e[1;36m"
ROJO="\e[31m"
ROJO_BRILLANTE="\e[1;31m"

VER="v2.6"

# Guardián contra ejecución innecesaria con 'sudo'
check_sudo_usage() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        echo -e "${ROJO_BRILLANTE}[!] ATENCIÓN: Has ejecutado el script con 'sudo'.${RESET}"
        echo -e "${AMARILLO}    Ejecutar con 'sudo' puede causar problemas de autorización gráfica (X11/Wayland)${RESET}"
        echo -e "${AMARILLO}    y conflictos de permisos en el socket QMP de tus máquinas virtuales.${RESET}\n"
        echo -e "${CIAN_BRILLANTE}[i] Sugerencia de uso:${RESET} Ejecuta el script de forma normal:"
        echo -e "    ${VERDE_BRILLANTE}./qemu4me.sh${RESET}\n"
        echo -e "El script te solicitará la clave 'sudo' únicamente cuando requiera levantar redes o asignar permisos."
        echo "--------------------------------------------------------------------"
        read -rp "Presiona Enter si deseas continuar de todos modos (o Ctrl+C para salir)..."
    fi
}
check_sudo_usage

mkdir -p "$VM_STORAGE_DIR" "$VM_CONFIG_DIR" "$QMP_DIR" "$PID_DIR" "$CAPTURE_DIR"
chmod 700 "$CONFIG_DIR" "$QMP_DIR" "$PID_DIR"

cleanup() {
    tput cnorm 2>/dev/null || true
    [[ -n "$TMP_OVA_DIR" && -d "$TMP_OVA_DIR" ]] && rm -rf "$TMP_OVA_DIR"
}
trap 'cleanup' EXIT

# Genera el texto del logo (sin ejecutar 'clear' para permitir integrarse en FZF)
get_logo_text() {
    local HORA_ACTUAL SEGUNDOS ULTIMO_DIGITO DIGITO_VER DIGITO_DASH
    local COLOR_LOGO COLOR_VER COLOR_DASH

    HORA_ACTUAL=$(date +"%H:%M:%S")
    SEGUNDOS=$(date +"%S")

    ULTIMO_DIGITO="${SEGUNDOS: -1}"
    case "$ULTIMO_DIGITO" in
        1) COLOR_LOGO="$AZUL_BRILLANTE" ;;
        2) COLOR_LOGO="$VERDE_BRILLANTE" ;;
        3) COLOR_LOGO="$AMARILLO_BRILLANTE" ;;
        4) COLOR_LOGO="$CIAN_BRILLANTE" ;;
        5) COLOR_LOGO="$ROJO_BRILLANTE" ;;
        6) COLOR_LOGO="$AZUL_CLARO" ;;
        7) COLOR_LOGO="$VERDE" ;;
        8) COLOR_LOGO="$AMARILLO" ;;
        9) COLOR_LOGO="$CIAN" ;;
        0) COLOR_LOGO="$ROJO" ;;
        *) COLOR_LOGO="$BLANCO_NEGRITA" ;;
    esac

    DIGITO_VER=$(( (10#$SEGUNDOS + 5) % 10 ))
    case "$DIGITO_VER" in
        1) COLOR_VER="$ROJO_BRILLANTE" ;;
        2) COLOR_VER="$CIAN" ;;
        3) COLOR_VER="$VERDE" ;;
        4) COLOR_VER="$AMARILLO" ;;
        5) COLOR_VER="$AZUL_BRILLANTE" ;;
        6) COLOR_VER="$VERDE_BRILLANTE" ;;
        7) COLOR_VER="$AMARILLO_BRILLANTE" ;;
        8) COLOR_VER="$CIAN_BRILLANTE" ;;
        9) COLOR_VER="$AZUL_CLARO" ;;
        0) COLOR_VER="$BLANCO_NEGRITA" ;;
        *) COLOR_VER="$CIAN" ;;
    esac

    DIGITO_DASH=$(( (10#$SEGUNDOS + 2) % 10 ))
    case "$DIGITO_DASH" in
        1) COLOR_DASH="$VERDE_BRILLANTE" ;;
        2) COLOR_DASH="$AMARILLO_BRILLANTE" ;;
        3) COLOR_DASH="$CIAN_BRILLANTE" ;;
        4) COLOR_DASH="$ROJO_BRILLANTE" ;;
        5) COLOR_DASH="$AZUL_CLARO" ;;
        6) COLOR_DASH="$VERDE" ;;
        7) COLOR_DASH="$AMARILLO" ;;
        8) COLOR_DASH="$CIAN" ;;
        9) COLOR_DASH="$ROJO" ;;
        0) COLOR_DASH="$BLANCO_NEGRITA" ;;
        *) COLOR_DASH="$GRIS_CLARO" ;;
    esac

    echo -e "${AZUL_BRILLANTE}--- ⚡ ${COLOR_LOGO}QEMU4ME${RESET} ${AZUL_OSCURO}| ${COLOR_DASH}PENTEST VM MANAGER${RESET} ${AZUL_OSCURO}| ${COLOR_VER}${VER}${RESET} ${BLANCO}:${HORA_ACTUAL}: ${AZUL_BRILLANTE}⚡---${RESET}"
}

show_logo() {
    clear
    get_logo_text
    echo ""
}

sanitize_name() {
    local input="$1"
    echo "$input" | sed -E 's/[^a-zA-Z0-9_-]//g'
}

confirm_action() {
    local prompt_msg="${1:-¿Deseas continuar?}"
    local default_choice="${2:-Sí}"
    
    local choice
    if [[ "$default_choice" == "Sí" ]]; then
        choice=$(echo -e "Sí\nNo" | fzf --prompt="$prompt_msg: " --height=20% --reverse)
    else
        choice=$(echo -e "No\nSí" | fzf --prompt="$prompt_msg: " --height=20% --reverse)
    fi

    [[ "$choice" == "Sí" ]]
}

check_free_space() {
    local path="$1"
    local required_bytes="$2"
    local available_bytes
    available_bytes=$(df --output=avail -B1 "$path" | tail -n1 | tr -d ' ')

    if (( available_bytes < required_bytes )); then
        local req_gb avail_gb
        req_gb=$(awk "BEGIN {printf \"%.2f\", $required_bytes/1073741824}")
        avail_gb=$(awk "BEGIN {printf \"%.2f\", $available_bytes/1073741824}")
        echo -e "\e[31m[!] Error: Espacio en disco insuficiente en $path.\e[0m"
        echo -e "\e[31m    Requerido: ${req_gb} GB | Disponible: ${avail_gb} GB\e[0m"
        return 1
    fi
    return 0
}

detect_accel() {
    if [[ -r /dev/kvm && -w /dev/kvm ]] && lsmod 2>/dev/null | grep -q kvm; then
        echo "-enable-kvm -cpu host,kvm=on"
    else
        echo "-accel tcg,thread=multi -cpu qemu64"
    fi
}

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="${USER:-$LOGNAME}"
    REAL_HOME="$HOME"
fi

ISO_SEARCH_DIRS=(
    "$REAL_HOME/ISOs"
    "$REAL_HOME/isos"
    "$REAL_HOME/Downloads"
    "$REAL_HOME/Descargas"
    "$REAL_HOME/VMs"
    "$REAL_HOME/vms"
    "$REAL_HOME/VirtualBox VMs"
    "$REAL_HOME/Documents"
    "$REAL_HOME/Documentos"
)

find_images() {
    local valid_dirs=()
    for d in "${ISO_SEARCH_DIRS[@]}"; do
        if [[ -d "$d" ]]; then
            valid_dirs+=("$d")
        fi
    done

    if [ ${#valid_dirs[@]} -eq 0 ]; then
        return 0
    fi

    find "${valid_dirs[@]}" -maxdepth 4 -type f \( -iname "*.iso" -o -iname "*.ova" \) 2>/dev/null
}

send_qmp_cmd() {
    local socket="$1"
    local cmd="$2"
    local lock_file="${socket}.lock"

    if [[ ! -S "$socket" ]]; then
        echo -e "\e[31m[!] Socket Unix no activo: $socket\e[0m"
        return 1
    fi

    exec 200>"$lock_file"
    flock -x -w 3 200 || { echo -e "\e[31m[!] Socket QMP ocupado.\e[0m"; return 1; }

    if command -v socat &>/dev/null; then
        echo "$cmd" | socat - "UNIX-CONNECT:$socket" 2>/dev/null
    elif nc -h 2>&1 | grep -q '\-U'; then
        echo "$cmd" | nc -U "$socket" 2>/dev/null
    else
        echo -e "\e[31m[!] Se requiere 'socat' o 'netcat-openbsd'.\e[0m"
        exec 200>&-
        return 1
    fi
    exec 200>&-
}

copy_to_clipboard() {
    local text="$1"
    if command -v xclip &>/dev/null; then
        echo -n "$text" | xclip -selection clipboard
        echo -e "\e[32m[✓] Copiado al portapapeles (xclip).\e[0m"
    elif command -v wl-copy &>/dev/null; then
        echo -n "$text" | wl-copy
        echo -e "\e[32m[✓] Copiado al portapapeles (wl-clipboard).\e[0m"
    else
        echo -e "\e[33m[!] No se detectó xclip ni wl-copy. Comando:\e[0m"
        echo -e "\e[36m$text\e[0m"
    fi
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            arch|manjaro|endeavouros) DISTRO="arch" ;;
            fedora|rhel|centos)      DISTRO="fedora" ;;
            ubuntu|debian|pop|kali)  DISTRO="debian" ;;
            *)
                if [[ "${ID_LIKE:-}" =~ "arch" ]]; then DISTRO="arch"
                elif [[ "${ID_LIKE:-}" =~ "fedora" ]]; then DISTRO="fedora"
                elif [[ "${ID_LIKE:-}" =~ "debian" ]]; then DISTRO="debian"
                else DISTRO="unknown"; fi
                ;;
        esac
    else
        DISTRO="unknown"
    fi
}

check_and_install_dependencies() {
    detect_distro
    local MISSING=()

    echo -e "\e[34m[+] Comprobando dependencias e infraestructura del sistema...\e[0m"

    case "$DISTRO" in
        arch)
            for pkg in qemu-desktop fzf gawk tar iproute2 openbsd-netcat socat xclip dnsmasq tcpdump; do
                pacman -Qq "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[33m[!] Instalando paquetes faltantes en Arch Linux: ${MISSING[*]}\e[0m"
                sudo pacman -S --needed --noconfirm "${MISSING[@]}"
            fi
            ;;
        fedora)
            for pkg in qemu-kvm fzf gawk tar iproute nc socat xclip dnsmasq tcpdump; do
                rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[33m[!] Instalando paquetes faltantes en Fedora: ${MISSING[*]}\e[0m"
                sudo dnf install -y "${MISSING[@]}"
            fi
            ;;
        debian)
            for pkg in qemu-system-x86 fzf gawk tar iproute2 netcat-openbsd socat xclip dnsmasq tcpdump; do
                dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[33m[!] Instalando paquetes faltantes en Debian/Ubuntu/Kali: ${MISSING[*]}\e[0m"
                sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
            fi
            ;;
    esac

    # Cargar módulo tun/tap si no está presente
    if ! lsmod | grep -q "^tun"; then
        echo -e "\e[34m[+] Cargando módulo del kernel 'tun'...\e[0m"
        sudo modprobe tun
    fi

    if [[ ! -c /dev/net/tun ]]; then
        echo -e "\e[34m[+] Creando nodo de dispositivo /dev/net/tun...\e[0m"
        sudo mkdir -p /dev/net
        sudo mknod /dev/net/tun c 10 200 2>/dev/null || true
        sudo chmod 0666 /dev/net/tun
    fi

    if [[ -d /etc/modules-load.d ]] && [[ ! -f /etc/modules-load.d/qemu4me-tun.conf ]]; then
        echo "tun" | sudo tee /etc/modules-load.d/qemu4me-tun.conf >/dev/null 2>&1 || true
        echo -e "\e[32m[✓] Persistencia de 'tun' configurada en /etc/modules-load.d/qemu4me-tun.conf\e[0m"
    fi

    # Cargar módulos KVM
    if ! lsmod | grep -q kvm; then
        echo -e "\e[34m[+] Cargando módulos KVM...\e[0m"
        sudo modprobe kvm 2>/dev/null || true
        sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    fi

    if [[ -n "${DISPLAY:-}" ]] && command -v xhost &>/dev/null; then
        xhost +si:localuser:root &>/dev/null || xhost +local:root &>/dev/null || true
    fi

    echo -e "\e[32m[✓] Entorno del sistema verificado y preparado correctamente.\e[0m\n"
}

get_bridge_interfaces() {
    ip -d link show type bridge | grep -E '^[0-9]+:' | awk -F': ' '{print $2}'
}

setup_lab_bridge() {
    local bridge_name="${1:-br-lab}"
    local tap_name="${2:-tap-lab}"
    local bridge_ip="${3:-192.168.100.1/24}"
    local dhcp_start="${4:-192.168.100.10}"
    local dhcp_end="${5:-192.168.100.100}"

    # 1. Habilitar Forwarding IPv4 en el Kernel
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    # 2. Crear Bridge L2 y asignar IP de Gateway Host
    if ! ip link show dev "$bridge_name" &>/dev/null; then
        sudo ip link add name "$bridge_name" type bridge
        sudo ip addr add "$bridge_ip" dev "$bridge_name"
        sudo ip link set dev "$bridge_name" up
    fi

    # 3. Crear Interfaz TAP y asociarla al Bridge ANTES de iniciar dnsmasq
    if ! ip link show dev "$tap_name" &>/dev/null; then
        sudo ip tuntap add dev "$tap_name" mode tap user "$REAL_USER"
        sudo ip link set dev "$tap_name" master "$bridge_name"
        sudo ip link set dev "$tap_name" up
    fi

    # 4. Reglas Permisivas de Firewall (Iptables / UFW) para Tráfico de Laboratorio
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        sudo ufw allow in on "$bridge_name" >/dev/null 2>&1
        sudo ufw route allow in on "$bridge_name" >/dev/null 2>&1
    fi
    sudo iptables -C FORWARD -i "$bridge_name" -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -i "$bridge_name" -j ACCEPT
    sudo iptables -C FORWARD -o "$bridge_name" -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -o "$bridge_name" -j ACCEPT

    # 5. Inicializar Dnsmasq escuchando estrictamente en el Bridge L2
    if command -v dnsmasq &>/dev/null; then
        local lease_file="/tmp/dnsmasq-$bridge_name.leases"
        local pid_file="/tmp/dnsmasq-$bridge_name.pid"

        if ! pgrep -F "$pid_file" &>/dev/null; then
            sudo touch "$lease_file"
            sudo chmod 666 "$lease_file"
            sudo dnsmasq \
                --interface="$bridge_name" \
                --bind-interfaces \
                --except-interface=lo \
                --dhcp-range="$dhcp_start,$dhcp_end,12h" \
                --dhcp-leasefile="$lease_file" \
                --pid-file="$pid_file" 2>/dev/null || true
        fi
    fi

    echo "$tap_name"
}

get_vm_ip_address() {
    local mac_addr="$1"
    local bridge_dev="${2:-br-lab}"

    if [[ -z "$mac_addr" || "$mac_addr" == "Desconocida" ]]; then
        echo "No detectada"
        return
    fi

    local mac_lower
    mac_lower=$(echo "$mac_addr" | tr '[:upper:]' '[:lower:]')
    local ip_found=""

    # CAPA 1: Inspección directa en los archivos Lease de dnsmasq
    local lease_files=(
        "/tmp/dnsmasq-${bridge_dev}.leases"
        /tmp/dnsmasq*.leases
        /var/lib/misc/dnsmasq.leases
    )
    for lf in "${lease_files[@]}"; do
        if [[ -f "$lf" ]]; then
            ip_found=$(grep -i "$mac_lower" "$lf" 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
            [[ -n "$ip_found" ]] && { echo "$ip_found"; return; }
        fi
    done

    # CAPA 2: Ping Broadcast al Rango de Red + Inspección de la Tabla Neighbor/ARP del Kernel
    local subnet_prefix
    subnet_prefix=$(ip -4 addr show dev "$bridge_dev" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)

    if [[ -n "$subnet_prefix" ]]; then
        local bcast_ip
        bcast_ip=$(ipcalc -b "$subnet_prefix" 2>/dev/null | cut -d'=' -f2 || echo "")
        [[ -z "$bcast_ip" ]] && bcast_ip="${subnet_prefix%.*}.255"

        # Inyección pasiva/activa de ICMP para forzar la actualización de tablas L2
        ping -c 2 -b -I "$bridge_dev" "$bcast_ip" >/dev/null 2>&1 || true

        ip_found=$(ip neighbor show dev "$bridge_dev" | grep -i "$mac_lower" | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
        [[ -n "$ip_found" ]] && { echo "$ip_found"; return; }
    fi

    # CAPA 3: Escaneo Activo L2 (arp-scan / nmap) filtrando por MAC persistente
    if [[ -n "$subnet_prefix" ]]; then
        if command -v arp-scan &>/dev/null; then
            ip_found=$(sudo arp-scan --interface="$bridge_dev" "$subnet_prefix" 2>/dev/null | grep -i "$mac_lower" | awk '{print $1}' | head -n1 || true)
        elif command -v nmap &>/dev/null; then
            ip_found=$(sudo nmap -sn -PR --send-eth -e "$bridge_dev" "$subnet_prefix" 2>/dev/null | grep -B 2 -i "$mac_lower" | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -n1 || true)
        fi
        [[ -n "$ip_found" ]] && { echo "$ip_found"; return; }
    fi

    echo "No detectada (Offline/Buscando...)"
}

select_ram() {
    local CHOICE
    CHOICE=$(echo -e "1024 MB (1GB)\n2048 MB (2GB)\n4096 MB (4GB)\n8192 MB (8GB)\nPersonalizado..." | fzf \
        --prompt="Seleccione Memoria RAM: " \
        --preview='case {} in
            *"1024"*) echo -e "1024 MB (1GB):\n - Recomendado para distribuciones muy ligeras, routers o sistemas CLI." ;;
            *"2048"*) echo -e "2048 MB (2GB):\n - Estándar equilibrado para la mayoría de entornos de pentesting." ;;
            *"4096"*) echo -e "4096 MB (4GB):\n - Recomendado para distros con entorno gráfico completo (Kali, Parrot)." ;;
            *"8192"*) echo -e "8192 MB (8GB):\n - Alto rendimiento para análisis intensivo o múltiples tareas." ;;
            *) echo -e "Personalizado:\n - Permite ingresar cualquier valor manual en MB." ;;
        esac' \
        --preview-window=right:50%:wrap)
    case "$CHOICE" in
        *"1024"*) echo "1024" ;;
        *"2048"*) echo "2048" ;;
        *"4096"*) echo "4096" ;;
        *"8192"*) echo "8192" ;;
        *)
            read -rp "--> Introduce RAM personalizada en MB [2048]: " CUSTOM_RAM
            CUSTOM_RAM=$(echo "${CUSTOM_RAM:-2048}" | tr -cd '0-9')
            echo "${CUSTOM_RAM:-2048}"
            ;;
    esac
}

select_cpus() {
    local CHOICE
    CHOICE=$(echo -e "1 CPU\n2 CPUs\n4 CPUs\n8 CPUs\nPersonalizado..." | fzf \
        --prompt="Seleccione vCPUs: " \
        --preview='case {} in
            *"1 CPU"*) echo -e "1 vCPU:\n - Rendimiento básico para máquinas livianas o de prueba." ;;
            *"2 CPUs"*) echo -e "2 vCPUs:\n - Configuración estándar rápida y eficiente para la mayoría de sistemas." ;;
            *"4 CPUs"*) echo -e "4 vCPUs:\n - Recomendado para tareas pesadas, escaneos masivos o compilación." ;;
            *"8 CPUs"*) echo -e "8 vCPUs:\n - Máxima capacidad de cómputo para auditorías complejas." ;;
            *) echo -e "Personalizado:\n - Introduce manualmente la cantidad exacta de vCPUs." ;;
        esac' \
        --preview-window=right:50%:wrap)
    case "$CHOICE" in
        *"1 CPU"*) echo "1" ;;
        *"2 CPUs"*) echo "2" ;;
        *"4 CPUs"*) echo "4" ;;
        *"8 CPUs"*) echo "8" ;;
        *)
            read -rp "--> Introduce vCPUs personalizadas [2]: " CUSTOM_CPUS
            CUSTOM_CPUS=$(echo "${CUSTOM_CPUS:-2}" | tr -cd '0-9')
            echo "${CUSTOM_CPUS:-2}"
            ;;
    esac
}

select_disk_size() {
    local CHOICE
    CHOICE=$(echo -e "10 GB (Ligero)\n20 GB (Estándar)\n40 GB (Medio)\n80 GB (Grande)\nPersonalizado..." | fzf \
        --prompt="Seleccione Tamaño de Disco QCOW2: " \
        --preview='case {} in
            *"10 GB"*) echo -e "10 GB:\n - Tamaño compacto para instalaciones mínimas." ;;
            *"20 GB"*) echo -e "20 GB:\n - Capacidad suficiente para sistemas operativos de pentesting comunes." ;;
            *"40 GB"*) echo -e "40 GB:\n - Recomendado si almacenarás herramientas adicionales o capturas." ;;
            *"80 GB"*) echo -e "80 GB:\n - Espacio amplio para análisis forense o almacenamiento pesado." ;;
            *) echo -e "Personalizado:\n - Ingresa un tamaño personalizado en GB." ;;
        esac' \
        --preview-window=right:50%:wrap)
    case "$CHOICE" in
        *"10 GB"*) echo "10" ;;
        *"20 GB"*) echo "20" ;;
        *"40 GB"*) echo "40" ;;
        *"80 GB"*) echo "80" ;;
        *)
            read -rp "--> Introduce tamaño de disco en GB [20]: " CUSTOM_DISK
            CUSTOM_DISK=$(echo "${CUSTOM_DISK:-20}" | tr -cd '0-9')
            echo "${CUSTOM_DISK:-20}"
            ;;
    esac
}

# Lógica de extracción/asignación dentro del flujo de creación de VM
configure_network() {
    echo -e "\n\e[34m[+] Modo de red:\e[0m"
    NET_MODE=$(echo -e "1. Bridge Aislado br-lab (Wi-Fi)\n2. Bridge Existente\n3. User/NAT + hostfwd" \
               | fzf --prompt="Red: ")

    # Si se extrajo previamente del .ovf se mantiene; si no, se fija con prefijo QEMU OUI (52:54:00)
    if [[ -n "${EXTRACTED_MAC:-}" ]]; then
        FINAL_MAC=$(echo "$EXTRACTED_MAC" | tr -cd '0-9A-Fa-f:')
    else
        FINAL_MAC=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    fi

    if [[ "$NET_MODE" =~ Aislado ]]; then
        TAP_DEV=$(setup_lab_bridge "br-lab" "tap-lab")
        NET_ARGS="-netdev tap,id=net0,ifname=$TAP_DEV,script=no,downscript=no -device e1000,netdev=net0,mac=$FINAL_MAC"
    elif [[ "$NET_MODE" =~ Existente ]]; then
        BRIDGES=$(get_bridge_interfaces)
        SELECTED_BRIDGE=$(echo "$BRIDGES" | fzf --prompt="Bridge: ")
        [[ -z "$SELECTED_BRIDGE" ]] && SELECTED_BRIDGE="br-lab"
        SELECTED_BRIDGE=$(sanitize_name "$SELECTED_BRIDGE")

        TAP_DEV=$(setup_lab_bridge "$SELECTED_BRIDGE" "tap-$SELECTED_BRIDGE")
        NET_ARGS="-netdev tap,id=net0,ifname=$TAP_DEV,script=no,downscript=no -device e1000,netdev=net0,mac=$FINAL_MAC"
    else
        read -rp "--> hostfwd (ej: tcp::2222-:22): " FWD_RULES
        local fwd=""
        if [[ -n "$FWD_RULES" ]]; then
            FWD_RULES=$(echo "$FWD_RULES" | tr -cd 'a-zA-Z0-9_,-:')
            IFS=',' read -ra ADDR <<< "$FWD_RULES"
            for i in "${ADDR[@]}"; do fwd+=",hostfwd=$i"; done
        fi
        NET_ARGS="-netdev user,id=net0${fwd} -device e1000,netdev=net0,mac=$FINAL_MAC"
    fi
}

launch_vm() {
    local vm_name="$1"; shift
    local script="$VM_CONFIG_DIR/${vm_name}.sh"
    local log="$CONFIG_DIR/${vm_name}.log"

    setsid nohup "$script" "$@" >"$log" 2>&1 < /dev/null &
    sleep 1.5

    if pgrep -f "qemu-system-x86_64.*-name $vm_name" >/dev/null; then
        echo -e "\e[32m[✓] VM '$vm_name' ejecutándose en background (PID: $(pgrep -f "qemu.*-name $vm_name" | head -1)).\e[0m"
        echo -e "\e[36m    Log: $log\e[0m"
    else
        echo -e "\e[31m[!] La VM no se pudo iniciar. Revisa el log: $log\e[0m"
        tail -n 15 "$log"
    fi
    read -rp "Presiona Enter para continuar..."
}

create_vm() {
    show_logo
    echo -e "\e[33m--- Creación de Nueva Máquina Virtual (Pentesting) ---\e[0m\n"

    read -rp "--> Nombre de la VM: " RAW_NAME
    VM_NAME=$(sanitize_name "$RAW_NAME")
    if [[ -z "$VM_NAME" || -f "$VM_CONFIG_DIR/${VM_NAME}.sh" ]]; then
        echo -e "\e[31m[!] Nombre inválido o la VM ya existe.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    echo -e "\n\e[34m[+] Buscando .iso y .ova en tus directorios...\e[0m"
    
    local raw_images
    raw_images=$(find_images)

    if [[ -z "$raw_images" ]]; then
        echo -e "\e[31m[!] No se encontraron archivos .iso o .ova en las rutas especificadas.\e[0m"
        echo -e "\e[33mRutas revisadas:\e[0m"
        printf ' - %s\n' "${ISO_SEARCH_DIRS[@]}"
        read -rp "Presiona Enter..."
        return
    fi

    IMAGE_PATH=$(echo "$raw_images" | fzf \
        --prompt="Selecciona ISO u OVA: " \
        --preview='file {} 2>/dev/null; echo "-------------------"; ls -lh {} 2>/dev/null' \
        --preview-window=right:50%:wrap)

    if [[ -z "$IMAGE_PATH" ]]; then
        echo -e "\e[31m[!] No se seleccionó ninguna imagen.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    VM_RAM=$(select_ram)
    VM_CPUS=$(select_cpus)

    DRIVE_ARGS=""
    CDROM_ARG=""

    EXTRACTED_MAC=""
    if [[ "$IMAGE_PATH" == *.ova ]]; then
        local file_size
        file_size=$(stat -c%s "$IMAGE_PATH" 2>/dev/null || stat -f%z "$IMAGE_PATH")
        local req_space=$(( file_size * 3 ))
        if ! check_free_space "$VM_STORAGE_DIR" "$req_space"; then
            read -rp "Presiona Enter..."
            return
        fi

        echo -e "\n\e[34m[+] Extrayendo OVA y parseando OVF...\e[0m"
        TMP_OVA_DIR=$(mktemp -d -t qemu4me-ova-XXXXXX)
        tar -xvf "$IMAGE_PATH" -C "$TMP_OVA_DIR"

        # Intentar extraer la MAC persistente del archivo .ovf
        local ovf_file
        ovf_file=$(find "$TMP_OVA_DIR" -type f -name "*.ovf" | head -n1)
        if [[ -n "$ovf_file" && -f "$ovf_file" ]]; then
            local raw_mac
            raw_mac=$(grep -iP 'MACAddress="?\K[0-9A-Fa-f]{12}' "$ovf_file" | head -n1 || true)
            if [[ -n "$raw_mac" ]]; then
                # ASEGÚRATE DE LIMPIAR CUALQUIER CARACTER EXTRAÑO O ESPACIO
                EXTRACTED_MAC=$(echo "$raw_mac" | tr -cd '0-9A-Fa-f' | sed -E 's/(..)/\1:/g; s/:$//' | tr '[:upper:]' '[:lower:]')
                echo -e "\e[32m[✓] MAC Original extraída del OVF: $EXTRACTED_MAC\e[0m"
            fi
        fi

        mapfile -t VMDK_FILES < <(find "$TMP_OVA_DIR" -type f -name "*.vmdk" | sort)
        if [ ${#VMDK_FILES[@]} -eq 0 ]; then
            echo -e "\e[31m[!] No se encontraron discos .vmdk dentro del paquete OVA.\e[0m"
            read -rp "Presiona Enter..."
            return
        fi

        for idx in "${!VMDK_FILES[@]}"; do
            vmdk="${VMDK_FILES[$idx]}"
            target_qcow2="$VM_STORAGE_DIR/${VM_NAME}.qcow2"
            if [ "$idx" -gt 0 ]; then
                target_qcow2="$VM_STORAGE_DIR/${VM_NAME}-disk${idx}.qcow2"
            fi
            echo -e "  └─ Convirtiendo ($((idx+1))/${#VMDK_FILES[@]}): $(basename "$vmdk") -> $(basename "$target_qcow2")"
            qemu-img convert -f vmdk -O qcow2 "$vmdk" "$target_qcow2"
            
            DRIVE_ARGS+="-drive file=\"$target_qcow2\",if=ide,index=$idx,media=disk,format=qcow2 "
        done

        rm -rf "$TMP_OVA_DIR"
        TMP_OVA_DIR=""
    fi

    configure_network

    DISPLAY_CHOICE=$(echo -e "Default GTK/SDL GUI (-display default)\nHeadless / Sin GUI (-display none)\nVNC Server :1 (-vnc :1)" | fzf \
        --prompt="Modo de Pantalla: " \
        --preview='case {} in
            *"Default"*) echo -e "Interfaz Gráfica Nativa:\n - Muestra la ventana de la VM directamente usando el gestor gráfico del sistema." ;;
            *"Headless"*) echo -e "Modo Headless:\n - Ejecuta la VM de forma completamente transparente en segundo plano." ;;
            *"VNC"*) echo -e "Servidor VNC:\n - Permite conectar a la VM a través del puerto VNC :1 (5901)." ;;
        esac' \
        --preview-window=right:50%:wrap)
    case "$DISPLAY_CHOICE" in
        *"Headless"*) DEFAULT_DISPLAY="-display none" ;;
        *"VNC"*)      DEFAULT_DISPLAY="-vnc :1" ;;
        *)            DEFAULT_DISPLAY="-display default" ;;
    esac

    MONITOR_SOCKET="$QMP_DIR/${VM_NAME}-monitor.sock"
    QMP_SOCKET="$QMP_DIR/${VM_NAME}-qmp.sock"
    PCAP_ARG=""

    if confirm_action "--> ¿Activar captura PCAP nativa?" "No"; then
        PCAP_PATH="$CONFIG_DIR/captures/${VM_NAME}_$(date +%Y%m%d_%H%M%S).pcap"
        PCAP_ARG="-object filter-dump,id=pcap0,netdev=net0,file=$PCAP_PATH"
    fi

    HELPER_BIN=$(which qemu-bridge-helper 2>/dev/null || find /usr -name qemu-bridge-helper 2>/dev/null | head -n1)

    VM_SCRIPT="$VM_CONFIG_DIR/${VM_NAME}.sh"
    cat <<EOF > "$VM_SCRIPT"
#!/usr/bin/env bash

rm -f "$MONITOR_SOCKET" "$QMP_SOCKET"

export DISPLAY="\${DISPLAY:-:0}"
export XAUTHORITY="\${XAUTHORITY:-$REAL_HOME/.Xauthority}"

DISPLAY_OPT="$DEFAULT_DISPLAY"
SNAPSHOT_OPT=""

for arg in "\$@"; do
    case \$arg in
        --vnc) DISPLAY_OPT="-vnc :1" ;;
        --headless) DISPLAY_OPT="-display none" ;;
        --gui) DISPLAY_OPT="-display default" ;;
        --snapshot|--sandbox) SNAPSHOT_OPT="-snapshot" ;;
    esac
done

umask 077

exec qemu-system-x86_64 \\
    -name "$VM_NAME" \\
    -enable-kvm \\
    -cpu host,kvm=on \\
    -smp $VM_CPUS \\
    -m $VM_RAM \\
    -device virtio-balloon-pci,id=balloon0 \\
    -device virtio-rng-pci,id=rng0 \\
    \$SNAPSHOT_OPT \\
    $DRIVE_ARGS \\
    $CDROM_ARG \\
    $NET_ARGS \\
    $PCAP_ARG \\
    -monitor unix:"$MONITOR_SOCKET",server,nowait \\
    -qmp unix:"$QMP_SOCKET",server,nowait \\
    -vga std \\
    \$DISPLAY_OPT
EOF

    chmod +x "$VM_SCRIPT"
    echo -e "\e[32m[✓] VM '$VM_NAME' registrada correctamente.\e[0m"

    if confirm_action "--> ¿Deseas arrancar la VM '$VM_NAME' ahora?" "Sí"; then
        echo -e "\n\e[34m[+] Iniciando la VM '$VM_NAME' en segundo plano...\e[0m"
        
        local log="$CONFIG_DIR/${VM_NAME}.log"
        setsid nohup "$VM_SCRIPT" >"$log" 2>&1 < /dev/null &
        sleep 3

        if pgrep -f "qemu-system-x86_64.*-name $VM_NAME" >/dev/null; then
            echo -e "\e[32m[✓] Estado: ACTIVA (PID: $(pgrep -f "qemu.*-name $VM_NAME" | head -1))\e[0m"
            
            echo -e "\e[34m[+] Esperando asignación de dirección IP...\e[0m"
            local mac
            mac=$(grep -o -E 'mac=[0-9A-Fa-f:]+' "$VM_SCRIPT" | cut -d'=' -f2 || echo "Desconocida")
            
            local ip_detected="No detectada"
            for i in {1..10}; do
                ip_detected=$(get_vm_ip_address "$mac")
                if [[ "$ip_detected" != *"No detectada"* ]]; then
                    break
                fi
                sleep 2
            done
            
            echo -e "  ├─ MAC: \e[33m$mac\e[0m"
            echo -e "  └─ IP Asignada: \e[32m$ip_detected\e[0m\n"
        else
            echo -e "\e[31m[!] La VM no pudo iniciarse correctamente. Revisa el log: $log\e[0m"
        fi
    fi

    read -rp "Presiona Enter para continuar..."
}

show_vm_header() {
    local vm_name="$1"
    local script_path="$VM_CONFIG_DIR/${vm_name}.sh"
    local monitor_socket="$QMP_DIR/${vm_name}-monitor.sock"

    echo -e "\e[34m====================================================================\e[0m"
    echo -e "\e[1m  VM SELECCIONADA: \e[33m$vm_name\e[0m"
    
    local mac
    mac=$(grep -o -E 'mac=[0-9A-Fa-f:]+' "$script_path" | cut -d'=' -f2 || echo "Desconocida")
    local hostfwd
    hostfwd=$(grep -o -E 'hostfwd=[^ ]+' "$script_path" | cut -d'=' -f2 | tr '\n' ' ' || echo "Ninguno")

    local vm_ip
    vm_ip=$(get_vm_ip_address "$mac")

    local disk_size="N/A"
    if [[ -f "$VM_STORAGE_DIR/${vm_name}.qcow2" ]]; then
        disk_size=$(du -sh "$VM_STORAGE_DIR/${vm_name}.qcow2" | cut -f1)
    fi

    local status_socket
    if [[ -S "$monitor_socket" ]]; then
        status_socket="\e[32mACTIVO\e[0m"
    else
        status_socket="\e[31mINACTIVO\e[0m"
    fi

    echo -e "  ├─ MAC: $mac"
    echo -e "  ├─ IP Asignada: \e[32m$vm_ip\e[0m"
    echo -e "  ├─ Hostfwd Activos: $hostfwd"
    echo -e "  ├─ Tamaño Disco Principal: $disk_size"
    echo -e "  └─ Monitor QEMU: $status_socket"
    echo -e "\e[34m====================================================================\e[0m\n"
}

qmp_control_menu() {
    local vm_name="$1"
    local monitor_socket="$QMP_DIR/${vm_name}-monitor.sock"

    if [[ ! -S "$monitor_socket" ]]; then
        echo -e "\e[31m[!] El socket del monitor no está activo. ¿Está corriendo la VM?\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    while true; do
        show_logo
        show_vm_header "$vm_name"
        echo -e "\e[33m--- Control Monitor QEMU (QMP) ---\e[0m\n"
        CMD_CHOICE=$(echo -e "1. Pausar VM (stop)\n2. Reanudar VM (cont)\n3. Reiniciar (system_reset)\n4. Memory Dump\n5. Consola Interactiva\n6. Volver" | fzf \
            --prompt="Comando: " \
            --preview='case {} in
                1*) echo -e "Pausar VM (stop):\n - Detiene la ejecución del procesador en tiempo real." ;;
                2*) echo -e "Reanudar VM (cont):\n - Restablece la ejecución de la VM pausada." ;;
                3*) echo -e "Reiniciar (system_reset):\n - Envía una señal de reinicio duro al sistema guest." ;;
                4*) echo -e "Memory Dump:\n - Extrae la memoria RAM actual a un archivo físico para análisis forense." ;;
                5*) echo -e "Consola Interactiva:\n - Abre conexión directa Unix Socket con QMP (vía socat o netcat)." ;;
                6*) echo -e "Volver:\n - Regresa al menú anterior." ;;
            esac' \
            --preview-window=right:50%:wrap)

        case "$CMD_CHOICE" in
            1*) send_qmp_cmd "$monitor_socket" "stop" ;;
            2*) send_qmp_cmd "$monitor_socket" "cont" ;;
            3*) send_qmp_cmd "$monitor_socket" "system_reset" ;;
            4*) 
                read -rp "--> Ruta de guardado para el Dump: " DUMP_PATH
                send_qmp_cmd "$monitor_socket" "pmemsave 0 0x10000000 $DUMP_PATH"
                echo -e "\e[32m[✓] Dump enviado.\e[0m"
                read -rp "Presiona Enter..."
                ;;
            5*)
                if command -v socat &>/dev/null; then
                    socat - "UNIX-CONNECT:$monitor_socket" || true
                else
                    nc -U "$monitor_socket" || true
                fi
                ;;
            *) break ;;
        esac
    done
}

quick_access_menu() {
    local vm_name="$1"
    local script_path="$VM_CONFIG_DIR/${vm_name}.sh"

    show_logo
    show_vm_header "$vm_name"
    echo -e "\e[33m--- Atajos y Acceso Rápido ---\e[0m\n"

    local fwd_rules
    fwd_rules=$(grep -o -E 'hostfwd=[^ ]+' "$script_path" | cut -d'=' -f2 || true)

    local labels=()
    local cmds=()

    if [[ -n "$fwd_rules" ]]; then
        while IFS= read -r rule; do
            local hport
            hport=$(echo "$rule" | cut -d':' -f3 | cut -d'-' -f1)
            labels+=("Copiar comando SSH (Puerto Host $hport)")
            cmds+=("ssh user@127.0.0.1 -p $hport")
        done <<< "$fwd_rules"
    fi

    labels+=("Copiar comando de ejecución directo")
    cmds+=("$script_path")

    local CHOICE
    CHOICE=$(printf "%s\n" "${labels[@]}" | fzf \
        --prompt="Selecciona Acción: " \
        --preview='echo -e "ACCION DE PORTAPAPELES:\n---------------------\nCopia la cadena exacta de ejecución o conexión al portapapeles."' \
        --preview-window=right:50%:wrap)
    [[ -z "$CHOICE" ]] && return

    for idx in "${!labels[@]}"; do
        if [[ "${labels[$idx]}" == "$CHOICE" ]]; then
            copy_to_clipboard "${cmds[$idx]}"
            read -rp "Presiona Enter..."
            return
        fi
    done
}

export_bundle() {
    local vm_name="$1"
    show_logo
    echo -e "\e[33m--- Exportar Bundle de VM (.tar.gz) ---\e[0m\n"

    local export_tar="$HOME/${vm_name}_bundle.tar.gz"
    local files_to_pack=("$VM_CONFIG_DIR/${vm_name}.sh")
    for d in "$VM_STORAGE_DIR/${vm_name}"*.qcow2; do
        [[ -f "$d" ]] && files_to_pack+=("$d")
    done

    tar -czvf "$export_tar" "${files_to_pack[@]}"
    echo -e "\e[32m[✓] Bundle exportado en: $export_tar\e[0m"
    read -rp "Presiona Enter..."
}

import_bundle() {
    show_logo
    echo -e "\e[33m--- Importar Bundle de VM (.tar.gz) ---\e[0m\n"

    read -rp "--> Ruta completa del .tar.gz: " BUNDLE_PATH
    if [[ ! -f "$BUNDLE_PATH" ]]; then
        echo -e "\e[31m[!] El archivo no existe.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    tar -xzvf "$BUNDLE_PATH" -C /
    echo -e "\e[32m[✓] Importación completada.\e[0m"
    read -rp "Presiona Enter..."
}

clone_vm() {
    show_logo
    echo -e "\e[33m--- Clonación Rápida (Linked Clone) ---\e[0m\n"

    local VMS=()
    while IFS= read -r file; do
        [[ -f "$file" ]] && VMS+=("$(basename "$file" .sh)")
    done < <(find "$VM_CONFIG_DIR" -name "*.sh" 2>/dev/null)

    if [ ${#VMS[@]} -eq 0 ]; then
        echo -e "\e[31m[!] No hay VMs registradas.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    SRC_VM=$(printf "%s\n" "${VMS[@]}" | fzf \
        --prompt="Selecciona VM Origen: " \
        --preview='vm="{}"
                   echo -e "DETALLES DE VM BASE:\n--------------------\nNombre: $vm"
                   echo ""
                   cat "'"$VM_CONFIG_DIR"'/$vm.sh" 2>/dev/null' \
        --preview-window=right:50%:wrap)
    [[ -z "$SRC_VM" ]] && return

    SRC_DISK="$VM_STORAGE_DIR/${SRC_VM}.qcow2"
    if [[ ! -f "$SRC_DISK" ]]; then
        echo -e "\e[31m[!] Disco base no encontrado: $SRC_DISK\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    read -rp "--> Nombre del Clon: " RAW_CLONE
    CLONE_NAME=$(sanitize_name "$RAW_CLONE")
    if [[ -z "$CLONE_NAME" || -f "$VM_CONFIG_DIR/${CLONE_NAME}.sh" ]]; then
        echo -e "\e[31m[!] Nombre inválido o ya existente.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    CLONE_DISK="$VM_STORAGE_DIR/${CLONE_NAME}.qcow2"
    qemu-img create -f qcow2 -b "$SRC_DISK" -F qcow2 "$CLONE_DISK"

    RAND_MAC=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    
    sed -e "s/-name \"$SRC_VM\"/-name \"$CLONE_NAME\"/g" \
        -e "s/${SRC_VM}.qcow2/${CLONE_NAME}.qcow2/g" \
        -e "s/mac=52:54:00:[0-9A-Fa-f:]*/mac=$RAND_MAC/g" \
        -e "s/${SRC_VM}-monitor.sock/${CLONE_NAME}-monitor.sock/g" \
        -e "s/${SRC_VM}-qmp.sock/${CLONE_NAME}-qmp.sock/g" \
        "$VM_CONFIG_DIR/${SRC_VM}.sh" > "$VM_CONFIG_DIR/${CLONE_NAME}.sh"

    chmod +x "$VM_CONFIG_DIR/${CLONE_NAME}.sh"
    echo -e "\e[32m[✓] Clon vinculado '$CLONE_NAME' creado exitosamente.\e[0m"
    read -rp "Presiona Enter..."
}

attach_resources() {
    local vm_name="$1"
    local script_path="$VM_CONFIG_DIR/${vm_name}.sh"

    show_logo
    show_vm_header "$vm_name"
    echo -e "\e[33m--- Gestión de Recursos (Discos e ISOs) ---\e[0m\n"
    RESOURCE_ACTION=$(echo -e "1. Adjuntar Disco Secundario QCOW2\n2. Adjuntar CD-ROM / ISO\n3. Volver" | fzf \
        --prompt="Acción: " \
        --preview='case {} in
            1*) echo -e "Adjuntar Disco Secundario QCOW2:\n - Crea y conecta un disco nuevo para almacenamiento independiente." ;;
            2*) echo -e "Adjuntar CD-ROM / ISO:\n - Asocia una imagen ISO como lectora de CD-ROM adicional." ;;
            3*) echo -e "Volver:\n - Regresa al menú anterior." ;;
        esac' \
        --preview-window=right:50%:wrap)

    case "$RESOURCE_ACTION" in
        1*)
            read -rp "--> Identificador del disco extra: " DISK_LABEL
            DISK_LABEL=$(sanitize_name "$DISK_LABEL")
            SEC_SIZE=$(select_disk_size)
            SEC_DISK_PATH="$VM_STORAGE_DIR/${vm_name}-${DISK_LABEL}.qcow2"
            
            qemu-img create -f qcow2 "$SEC_DISK_PATH" "${SEC_SIZE}G"
            sed -i "/exec qemu-system-x86_64/a \    -drive file=\"$SEC_DISK_PATH\",if=virtio,format=qcow2 \\\\" "$script_path"
            echo -e "\e[32m[✓] Disco secundario añadido.\e[0m"
            read -rp "Presiona Enter..."
            ;;
        2*)
            ISO_PATH=$(find_images | fzf \
                --prompt="Selecciona ISO Secundaria: " \
                --preview='file {} 2>/dev/null; echo "-------------------"; ls -lh {} 2>/dev/null' \
                --preview-window=right:50%:wrap)
            if [[ -n "$ISO_PATH" ]]; then
                sed -i "/exec qemu-system-x86_64/a \    -drive file=\"$ISO_PATH\",media=cdrom \\\\" "$script_path"
                echo -e "\e[32m[✓] ISO vinculada como CD-ROM.\e[0m"
            fi
            read -rp "Presiona Enter..."
            ;;
        *) return ;;
    esac
}

manage_snapshots() {
    local vm_name="$1"
    local primary_disk="$VM_STORAGE_DIR/${vm_name}.qcow2"

    if [[ ! -f "$primary_disk" ]]; then
        echo -e "\e[31m[!] No se encontró el disco principal para instantáneas.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    while true; do
        show_logo
        show_vm_header "$vm_name"
        echo -e "\e[33m--- Gestión de Snapshots ---\e[0m\n"
        
        SNAP_ACTION=$(echo -e "1. Crear Snapshot\n2. Listar Snapshots\n3. Restaurar Snapshot\n4. Eliminar Snapshot\n5. Volver" | fzf \
            --prompt="Acción: " \
            --preview='case {} in
                1*) echo -e "Crear Snapshot:\n - Guarda un punto de restauración exacto del disco en su estado actual." ;;
                2*) echo -e "Listar Snapshots:\n - Muestra las instantáneas almacenadas dentro del disco QCOW2." ;;
                3*) echo -e "Restaurar Snapshot:\n - Regresa el disco al estado de una instantánea seleccionada." ;;
                4*) echo -e "Eliminar Snapshot:\n - Borra permanentemente una instantánea del disco." ;;
                5*) echo -e "Volver:\n - Regresa al menú anterior." ;;
            esac' \
            --preview-window=right:50%:wrap)

        case "$SNAP_ACTION" in
            1*)
                read -rp "--> Nombre del Snapshot: " RAW_SNAP
                SNAP_NAME=$(sanitize_name "$RAW_SNAP")
                if [[ -n "$SNAP_NAME" ]]; then
                    qemu-img snapshot -c "$SNAP_NAME" "$primary_disk"
                    echo -e "\e[32m[✓] Snapshot '$SNAP_NAME' creado.\e[0m"
                fi
                read -rp "Presiona Enter..."
                ;;
            2*)
                echo -e "\e[34m[+] Snapshots en disco:\e[0m"
                qemu-img snapshot -l "$primary_disk" || echo "Sin snapshots."
                read -rp "Presiona Enter..."
                ;;
            3*)
                mapfile -t SNAPS < <(qemu-img snapshot -l "$primary_disk" | tail -n +3 | awk '{print $2}')
                if [ ${#SNAPS[@]} -eq 0 ]; then
                    echo -e "\e[31m[!] No hay snapshots disponibles.\e[0m"
                else
                    TARGET_SNAP=$(printf "%s\n" "${SNAPS[@]}" | fzf --prompt="Restaurar: ")
                    if [[ -n "$TARGET_SNAP" ]]; then
                        qemu-img snapshot -a "$TARGET_SNAP" "$primary_disk"
                        echo -e "\e[32m[✓] Snapshot restaurado.\e[0m"
                    fi
                fi
                read -rp "Presiona Enter..."
                ;;
            4*)
                mapfile -t SNAPS < <(qemu-img snapshot -l "$primary_disk" | tail -n +3 | awk '{print $2}')
                if [ ${#SNAPS[@]} -eq 0 ]; then
                    echo -e "\e[31m[!] No hay snapshots disponibles.\e[0m"
                else
                    TARGET_SNAP=$(printf "%s\n" "${SNAPS[@]}" | fzf --prompt="Eliminar: ")
                    if [[ -n "$TARGET_SNAP" ]]; then
                        qemu-img snapshot -d "$TARGET_SNAP" "$primary_disk"
                        echo -e "\e[31m[✓] Snapshot eliminado.\e[0m"
                    fi
                fi
                read -rp "Presiona Enter..."
                ;;
            *) break ;;
        esac
    done
}

manage_vms() {
    show_logo
    echo -e "\e[33m--- Gestión de Máquinas Virtuales ---\e[0m\n"

    local VMS=()
    while IFS= read -r file; do
        [[ -f "$file" ]] && VMS+=("$(basename "$file" .sh)")
    done < <(find "$VM_CONFIG_DIR" -name "*.sh" 2>/dev/null)

    if [ ${#VMS[@]} -eq 0 ]; then
        echo -e "\e[31m[!] No hay máquinas virtuales registradas.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    SELECTED_VM=$(printf "%s\n" "${VMS[@]}" | fzf \
        --prompt="Selecciona una VM: " \
        --preview='vm="{}"
                   echo -e "INFORMACIÓN DE MÁQUINA VIRTUAL:\n--------------------------------"
                   echo "Nombre: $vm"
                   echo ""
                   if [[ -f "'"$VM_STORAGE_DIR"'/$vm.qcow2" ]]; then
                       echo "Tamaño de Disco: $(du -sh "'"$VM_STORAGE_DIR"'/$vm.qcow2" | cut -f1)"
                   fi
                   if pgrep -f "qemu-system-x86_64.*-name $vm" >/dev/null; then
                       echo "Estado: ACTIVA (PID: $(pgrep -f "qemu.*-name $vm" | head -1))"
                   else
                       echo "Estado: INACTIVA"
                   fi
                   echo ""
                   echo "Script de configuración:"
                   cat "'"$VM_CONFIG_DIR"'/$vm.sh" 2>/dev/null' \
        --preview-window=right:50%:wrap)
    [[ -z "$SELECTED_VM" ]] && return

    while true; do
        show_logo
        show_vm_header "$SELECTED_VM"

        ACTION=$(echo -e "Arrancar (GUI)\nArrancar Sandbox / Read-Only (-snapshot)\nArrancar (VNC Server :1)\nArrancar (Headless / Sin GUI)\nAcceso Rápido / Copiar Comandos\nControl QMP / Monitor\nGestionar Snapshots\nAdjuntar Discos/ISOs\nExportar Bundle (.tar.gz)\nApagar Forzado (Kill)\nEliminar VM (Script + Discos)\nVolver" | fzf \
            --prompt="Acción [$SELECTED_VM]: " \
            --preview='case {} in
                *"GUI") echo -e "Arrancar (GUI):\n - Abre la máquina virtual con ventana gráfica local." ;;
                *"Sandbox"*) echo -e "Modo Sandbox / Read-Only:\n - Los cambios realizados en el disco se descartan al apagar la VM (-snapshot)." ;;
                *"VNC"*) echo -e "Arrancar VNC:\n - Permite conectar remotamente a la VM por puerto VNC 5901." ;;
                *"Headless"*) echo -e "Arrancar Headless:\n - Arranca la VM en segundo plano de forma silenciosa." ;;
                *"Acceso Rápido"*) echo -e "Acceso Rápido:\n - Copia comandos de atajo o instrucciones SSH al portapapeles." ;;
                *"Control QMP"*) echo -e "Control QMP:\n - Acceso a pausa, reanudación, reinicio e inspección de RAM." ;;
                *"Snapshots"*) echo -e "Snapshots:\n - Administrar puntos de restauración en el disco QCOW2." ;;
                *"Adjuntar"*) echo -e "Adjuntar Recursos:\n - Asocia unidades de almacenamiento secundario o imágenes ISO." ;;
                *"Exportar"*) echo -e "Exportar Bundle:\n - Genera un archivo tar.gz comprimido con la VM y sus discos." ;;
                *"Apagar"*) echo -e "Apagar Forzado:\n - Detiene el proceso de la máquina inmediatamente." ;;
                *"Eliminar"*) echo -e "Eliminar VM:\n - Borra de forma irreversible la VM, su script y todos sus discos." ;;
                *) echo -e "Volver:\n - Regresa al menú principal." ;;
            esac' \
            --preview-window=right:50%:wrap)

        case "$ACTION" in
            *"Arrancar (GUI)"*)       launch_vm "$SELECTED_VM" --gui ;;
            *"Sandbox"*)              launch_vm "$SELECTED_VM" --snapshot --gui ;;
            *"Arrancar (VNC"*)        launch_vm "$SELECTED_VM" --vnc ;;
            *"Arrancar (Headless"*)   launch_vm "$SELECTED_VM" --headless ;;
            *"Acceso Rápido"*)       quick_access_menu "$SELECTED_VM" ;;
            *"Control QMP"*)          qmp_control_menu "$SELECTED_VM" ;;
            *"Snapshots"*)            manage_snapshots "$SELECTED_VM" ;;
            *"Adjuntar"*)             attach_resources "$SELECTED_VM" ;;
            *"Exportar"*)             export_bundle "$SELECTED_VM" ;;
            *"Apagar"*)
                if pkill -f "qemu-system-x86_64.*-name $SELECTED_VM"; then
                    echo -e "\e[33m[!] Proceso detenido correctamente.\e[0m"
                    rm -f "$QMP_DIR/${SELECTED_VM}"*.sock
                else
                    echo -e "\e[31m[!] La VM no estaba en ejecución.\e[0m"
                fi
                read -rp "Presiona Enter..."
                ;;
            *"Eliminar"*)
                if confirm_action "¿Confirmas eliminar '$SELECTED_VM' y TODOS sus discos?" "No"; then
                    pkill -f "qemu-system-x86_64.*-name $SELECTED_VM" 2>/dev/null || true
                    rm -f "$VM_CONFIG_DIR/${SELECTED_VM}.sh"
                    rm -f "$VM_STORAGE_DIR/${SELECTED_VM}"*.qcow2
                    rm -f "$QMP_DIR/${SELECTED_VM}"*.sock
                    echo -e "\e[31m[✓] VM eliminada.\e[0m"
                    read -rp "Presiona Enter para continuar..."
                    break
                fi
                ;;
            *) break ;;
        esac
    done
}

main_menu() {
    check_and_install_dependencies
    while true; do
        clear
        local logo_header
        logo_header=$(get_logo_text)

        local options=(
            "1. Crear VM Vulnerable"
            "2. Gestionar / Listar VMs"
            "3. Clonación Rápida (Linked)"
            "4. Importar Bundle (.tar.gz)"
            "5. Salir"
        )

        MENU_OPTION=$(printf "%s\n" "${options[@]}" | fzf \
            --ansi \
            --header="$logo_header" \
            --prompt="Selecciona una acción: " \
            --reverse \
            --height=100% \
            --border \
            --preview='case {} in
                1*) echo -e "DETALLES DE LA OPCIÓN:\n--------------------\nCrear VM Vulnerable:\n - Despliega una nueva máquina a partir de imágenes ISO u OVA descargadas." ;;
                2*) echo -e "DETALLES DE LA OPCIÓN:\n--------------------\nGestionar / Listar VMs:\n - Arranca, detén, apaga, elimina o administra el estado de tus VMs." ;;
                3*) echo -e "DETALLES DE LA OPCIÓN:\n--------------------\nClonación Rápida (Linked):\n - Crea un clon liviano e instantáneo vinculado a un disco base existente." ;;
                4*) echo -e "DETALLES DE LA OPCIÓN:\n--------------------\nImportar Bundle (.tar.gz):\n - Restaura y registra una máquina virtual exportada previamente." ;;
                5*) echo -e "DETALLES DE LA OPCIÓN:\n--------------------\nSalir:\n - Cierra el gestor QEMU4ME." ;;
            esac' \
            --preview-window=right:50%:wrap)

        case "$MENU_OPTION" in
            1*) create_vm ;;
            2*) manage_vms ;;
            3*) clone_vm ;;
            4*) import_bundle ;;
            5*|*) break ;;
        esac
    done
}

main_menu