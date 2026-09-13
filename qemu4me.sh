#!/usr/bin/env bash

# ==============================================================================
#  qemu4me - Gestor ultraligero de VMs para Pentesting (QEMU Nativo + Bridge)
# ==============================================================================

set -eo pipefail

CONFIG_DIR="$HOME/.config/qemu4me"
VM_STORAGE_DIR="$CONFIG_DIR/disks"
VM_CONFIG_DIR="$CONFIG_DIR/vms"
ISO_SEARCH_DIR="$HOME"
TMP_OVA_DIR=""

mkdir -p "$VM_STORAGE_DIR" "$VM_CONFIG_DIR"

cleanup() {
    tput cnorm 2>/dev/null || true
    if [[ -n "$TMP_OVA_DIR" && -d "$TMP_OVA_DIR" ]]; then
        rm -rf "$TMP_OVA_DIR"
    fi
}

trap 'cleanup' EXIT SIGINT SIGTERM

show_logo() {
    clear
    echo -e "\e[36m"
    cat << "EOF"
  ██████╗ ███████╗███╗   ███╗██╗  ██╗███╗   ███╗███████╗
 ██╔═══██╗██╔════╝████╗ ████║██║  ██║████╗ ████║██╔════╝
 ██║   ██║█████╗  ██╔████╔██║███████║██╔████╔██║█████╗  
 ██║▄▄ ██║██╔══╝  ██║╚██╔╝██║╚════██║██║╚██╔╝██║██╔══╝  
 ╚██████╔╝███████╗██║ ╚═╝ ██║     ██║██║ ╚═╝ ██║███████╗
  ╚══▀▀═╝ ╚══════╝╚═╝     ╚═╝     ╚═╝╚═╝     ╚═╝╚══════╝
EOF
    echo -e "\e[33m         -- CLI VM Manager for Pentesting (Pure QEMU + Bridge) --\e[0m\n"
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            arch|manjaro|endeavouros) DISTRO="arch" ;;
            fedora|rhel|centos)      DISTRO="fedora" ;;
            ubuntu|debian|pop|kali)  DISTRO="debian" ;;
            *)
                if [[ "$ID_LIKE" =~ "arch" ]]; then DISTRO="arch"
                elif [[ "$ID_LIKE" =~ "fedora" ]]; then DISTRO="fedora"
                elif [[ "$ID_LIKE" =~ "debian" ]]; then DISTRO="debian"
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

    case "$DISTRO" in
        arch)
            for pkg in qemu-desktop fzf gawk tar iproute2; do
                pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Arch...\e[0m"
                sudo pacman -S --needed --noconfirm "${MISSING[@]}"
            fi
            ;;
        fedora)
            for pkg in qemu-kvm fzf gawk tar iproute; do
                rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Fedora...\e[0m"
                sudo dnf install -y "${MISSING[@]}"
            fi
            ;;
        debian)
            for pkg in qemu-system-x86 fzf gawk tar iproute2; do
                dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Debian/Ubuntu...\e[0m"
                sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
            fi
            ;;
    esac

    # Comprobar si /etc/qemu/bridge.conf existe para evitar errores en modo bridge
    if [[ ! -f /etc/qemu/bridge.conf ]]; then
        echo -e "\e[33m[!] Configurando /etc/qemu/bridge.conf para el modo bridge...\e[0m"
        sudo mkdir -p /etc/qemu
        echo "allow all" | sudo tee /etc/qemu/bridge.conf >/dev/null
        sudo chmod 640 /etc/qemu/bridge.conf
    fi

    # Cargar módulo KVM
    if ! lsmod | grep -q kvm; then
        sudo modprobe kvm 2>/dev/null || true
        sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    fi
}

get_bridge_interfaces() {
    # Lista interfaces físicas/virtuales tipo bridge activas en el sistema
    ip -d link show type bridge | grep -E '^[0-9]+:' | awk -F': ' '{print $2}'
}

create_vm() {
    show_logo
    echo -e "\e[33m--- Creación de Nueva Máquina Virtual (Pentesting) ---\e[0m\n"

    read -rp "--> Nombre de la VM: " RAW_NAME
    VM_NAME=$(echo "$RAW_NAME" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$VM_NAME" ]]; then
        echo -e "\e[31m[!] Nombre inválido.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    if [[ -f "$VM_CONFIG_DIR/${VM_NAME}.sh" ]]; then
        echo -e "\e[31m[!] Ya existe una VM con ese nombre.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    echo -e "\n\e[34m[+] Buscando .iso y .ova en $ISO_SEARCH_DIR...\e[0m"
    IMAGE_PATH=$(find "$ISO_SEARCH_DIR" -type f \( -name "*.iso" -o -name "*.ova" \) 2>/dev/null | fzf --prompt="Selecciona ISO u OVA: ")
    if [[ -z "$IMAGE_PATH" ]]; then
        echo -e "\e[31m[!] No se seleccionó ninguna imagen.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    read -rp "--> Memoria RAM en MB [2048]: " VM_RAM; VM_RAM=${VM_RAM:-2048}
    read -rp "--> vCPUs [2]: " VM_CPUS; VM_CPUS=${VM_CPUS:-2}

    DISCO_PATH="$VM_STORAGE_DIR/${VM_NAME}.qcow2"

    if [[ "$IMAGE_PATH" == *.ova ]]; then
        echo -e "\n\e[34m[+] Extrayendo paquete OVA...\e[0m"
        TMP_OVA_DIR=$(mktemp -d -t qemu4me-ova-XXXXXX)
        tar -xvf "$IMAGE_PATH" -C "$TMP_OVA_DIR"

        VMDK_FILE=$(find "$TMP_OVA_DIR" -type f -name "*.vmdk" | head -n 1)
        if [[ -z "$VMDK_FILE" ]]; then
            echo -e "\e[31m[!] No se encontró ningún disco .vmdk en el OVA.\e[0m"
            read -rp "Presiona Enter..."
            return
        fi

        echo -e "\e[34m[+] Convirtiendo VMDK a QCOW2...\e[0m"
        qemu-img convert -f vmdk -O qcow2 "$VMDK_FILE" "$DISCO_PATH"
        rm -rf "$TMP_OVA_DIR"
        TMP_OVA_DIR=""
        CDROM_ARG=""
    else
        read -rp "--> Tamaño del disco en GB [20]: " DISK_SIZE; DISK_SIZE=${DISK_SIZE:-20}
        echo -e "\e[34m[+] Creando disco QCOW2 blanco...\e[0m"
        qemu-img create -f qcow2 "$DISCO_PATH" "${DISK_SIZE}G"
        CDROM_ARG="-cdrom \"$IMAGE_PATH\" -boot order=d"
    fi

    # Configuración de Red Modo Bridge
    echo -e "\n\e[34m[+] Configuración de Red para Pentesting:\e[0m"
    BRIDGES=$(get_bridge_interfaces)

    if [[ -z "$BRIDGES" ]]; then
        echo -e "\e[33m[!] No se detectaron interfaces 'bridge' activas en el sistema.\e[0m"
        echo -e "\e[33m[!] Creando un puerto puente por defecto 'br0' temporal con iproute2...\e[0m"
        sudo ip link add name br0 type bridge
        sudo ip link set dev br0 up
        SELECTED_BRIDGE="br0"
    else
        SELECTED_BRIDGE=$(echo "$BRIDGES" | fzf --prompt="Selecciona la interfaz Bridge: ")
    fi

    if [[ -z "$SELECTED_BRIDGE" ]]; then
        echo -e "\e[31m[!] Selección de red cancelada.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    # Argumentos de red QEMU Bridge
    # Se añade una dirección MAC aleatoria única para evitar colisiones en la subred
    RAND_MAC=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    NET_ARGS="-netdev bridge,id=net0,br=$SELECTED_BRIDGE -device virtio-net-pci,netdev=net0,mac=$RAND_MAC"

    # Guardar script de arranque de la VM
    VM_SCRIPT="$VM_CONFIG_DIR/${VM_NAME}.sh"
    cat <<EOF > "$VM_SCRIPT"
#!/usr/bin/env bash
qemu-system-x86_64 \\
    -enable-kvm \\
    -name "$VM_NAME" \\
    -m $VM_RAM \\
    -smp $VM_CPUS \\
    -drive file="$DISCO_PATH",if=virtio,format=qcow2 \\
    $CDROM_ARG \\
    $NET_ARGS \\
    -vga virtio \\
    -display default \\
    "\$@"
EOF

    chmod +x "$VM_SCRIPT"

    echo -e "\n\e[32m[✓] ¡VM '$VM_NAME' configurada en modo Bridge ($SELECTED_BRIDGE)!\e[0m"
    echo -e "Dirección MAC asignada: \e[36m$RAND_MAC\e[0m"
    
    read -rp "¿Deseas arrancarla ahora? (S/n): " START_NOW
    START_NOW=${START_NOW:-S}
    if [[ "$START_NOW" =~ ^[Ss]$ ]]; then
        "$VM_SCRIPT" &
        echo -e "\e[32m[+] Proceso QEMU ejecutándose en segundo plano.\e[0m"
    fi
    read -rp "Presiona Enter para continuar..."
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
        read -rp "Presiona Enter para continuar..."
        return
    fi

    SELECTED_VM=$(printf "%s\n" "${VMS[@]}" | fzf --prompt="Selecciona una VM: ")
    [[ -z "$SELECTED_VM" ]] && return

    if pgrep -f "qemu-system-x86_64.*-name $SELECTED_VM" > /dev/null; then
        STATUS="\e[32m[EN EJECUCIÓN]\e[0m"
    else
        STATUS="\e[31m[APAGADA]\e[0m"
    fi

    echo -e "Estado de $SELECTED_VM: $STATUS\n"
    ACTION=$(echo -e "Arrancar (Start)\nApagar Forzado (Kill)\nEliminar VM (Borrar Script + Disco)\nVolver" | fzf --prompt="Acción [$SELECTED_VM]: ")

    case "$ACTION" in
        *"Arrancar"*)
            if pgrep -f "qemu-system-x86_64.*-name $SELECTED_VM" > /dev/null; then
                echo -e "\e[33m[!] La VM ya está en ejecución.\e[0m"
            else
                "$VM_CONFIG_DIR/${SELECTED_VM}.sh" &
                echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada en segundo plano.\e[0m"
            fi
            ;;
        *"Apagar"*)
            if pkill -f "qemu-system-x86_64.*-name $SELECTED_VM"; then
                echo -e "\e[33m[!] Proceso QEMU finalizado.\e[0m"
            else
                echo -e "\e[31m[!] La VM no estaba en ejecución.\e[0m"
            fi
            ;;
        *"Eliminar"*)
            read -rp "¿Confirmas eliminar '$SELECTED_VM' y su disco permanentemente? (s/N): " CONF
            if [[ "$CONF" =~ ^[Ss]$ ]]; then
                pkill -f "qemu-system-x86_64.*-name $SELECTED_VM" 2>/dev/null || true
                rm -f "$VM_CONFIG_DIR/${SELECTED_VM}.sh"
                rm -f "$VM_STORAGE_DIR/${SELECTED_VM}.qcow2"
                echo -e "\e[31m[✓] VM eliminada.\e[0m"
            fi
            ;;
    esac
    read -rp "Presiona Enter para continuar..."
}

main_menu() {
    check_and_install_dependencies
    while true; do
        show_logo
        MENU_OPTION=$(echo -e "1. Crear nueva VM vulnerable (ISO / OVA)\n2. Gestionar / Listar VMs\n3. Salir" | fzf --prompt="Selecciona: ")
        case "$MENU_OPTION" in
            1*) create_vm ;;
            2*) manage_vms ;;
            3*) exit 0 ;;
            *) exit 0 ;;
        esac
    done
}

main_menu