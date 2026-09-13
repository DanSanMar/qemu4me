#!/usr/bin/env bash

# ==============================================================================
#  qemu4me - Gestor ultraligero de VMs para Pentesting (QEMU Nativo)
#  Auditoría & Hardening: DevSecOps Standard
# ==============================================================================

set -eo pipefail

CONFIG_DIR="$HOME/.config/qemu4me"
VM_STORAGE_DIR="$CONFIG_DIR/disks"
VM_CONFIG_DIR="$CONFIG_DIR/vms"
QMP_DIR="$CONFIG_DIR/qmp"
ISO_SEARCH_DIR="$HOME"
TMP_OVA_DIR=""

mkdir -p "$VM_STORAGE_DIR" "$VM_CONFIG_DIR" "$QMP_DIR"
chmod 700 "$CONFIG_DIR" "$QMP_DIR"

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
    echo -e "\e[33m         -- Hardened VM Manager for Pentesting (Pure QEMU) --\e[0m\n"
}

sanitize_name() {
    local input="$1"
    echo "$input" | sed -E 's/[^a-zA-Z0-9_-]//g'
}

check_free_space() {
    local path="$1"
    local required_bytes="$2"
    local available_bytes
    available_bytes=$(df --output=avail -B1 "$path" | tail -n1 | tr -d ' ')

    if (( available_bytes < required_bytes )); then
        local req_gb
        req_gb=$(awk "BEGIN {printf \"%.2f\", $required_bytes/1073741824}")
        local avail_gb
        avail_gb=$(awk "BEGIN {printf \"%.2f\", $available_bytes/1073741824}")
        echo -e "\e[31m[!] Error: Espacio en disco insuficiente en $path.\e[0m"
        echo -e "\e[31m    Requerido: ${req_gb} GB | Disponible: ${avail_gb} GB\e[0m"
        return 1
    fi
    return 0
}

send_qmp_cmd() {
    local socket="$1"
    local cmd="$2"

    if [[ ! -S "$socket" ]]; then
        echo -e "\e[31m[!] Socket Unix no activo: $socket\e[0m"
        return 1
    fi

    if command -v socat &>/dev/null; then
        echo "$cmd" | socat - "UNIX-CONNECT:$socket" 2>/dev/null
    elif nc -h 2>&1 | grep -q '\-U'; then
        echo "$cmd" | nc -U "$socket" 2>/dev/null
    else
        echo -e "\e[31m[!] Error: Se requiere 'socat' o 'netcat-openbsd' (nc -U) para comunicación QMP.\e[0m"
        return 1
    fi
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
            for pkg in qemu-desktop fzf gawk tar iproute2 openbsd-netcat socat xclip; do
                pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Arch...\e[0m"
                sudo pacman -S --needed --noconfirm "${MISSING[@]}"
            fi
            ;;
        fedora)
            for pkg in qemu-kvm fzf gawk tar iproute nc socat xclip; do
                rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Fedora...\e[0m"
                sudo dnf install -y "${MISSING[@]}"
            fi
            ;;
        debian)
            for pkg in qemu-system-x86 fzf gawk tar iproute2 netcat-openbsd socat xclip; do
                dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Debian/Ubuntu/Kali...\e[0m"
                sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
            fi
            ;;
    esac

    # Hardening & Configuración de Bridge Helper y ACLs
    if [[ ! -f /etc/qemu/bridge.conf ]]; then
        echo -e "\e[33m[!] Configurando /etc/qemu/bridge.conf para el modo bridge...\e[0m"
        sudo mkdir -p /etc/qemu
        echo "allow all" | sudo tee /etc/qemu/bridge.conf >/dev/null
        sudo chmod 640 /etc/qemu/bridge.conf
    else
        if ! grep -q "allow all" /etc/qemu/bridge.conf; then
            echo -e "\e[33m[!] Añadiendo 'allow all' a /etc/qemu/bridge.conf...\e[0m"
            echo "allow all" | sudo tee -a /etc/qemu/bridge.conf >/dev/null
        fi
    fi

    local HELPER_PATHS=(
        "/usr/lib/qemu/qemu-bridge-helper"
        "/usr/libexec/qemu-bridge-helper"
        "/usr/lib/qemu-kvm/qemu-bridge-helper"
    )

    for helper in "${HELPER_PATHS[@]}"; do
        if [[ -f "$helper" ]]; then
            if [[ ! -u "$helper" ]]; then
                echo -e "\e[33m[!] Asignando permisos SUID a $helper...\e[0m"
                sudo chmod u+s "$helper" 2>/dev/null || chmod 4755 "$helper" 2>/dev/null || true
            fi
        fi
    done

    if ! lsmod | grep -q kvm; then
        sudo modprobe kvm 2>/dev/null || true
        sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    fi
}

get_bridge_interfaces() {
    ip -d link show type bridge | grep -E '^[0-9]+:' | awk -F': ' '{print $2}'
}

get_vm_ip_address() {
    local mac_addr="$1"
    if [[ -z "$mac_addr" || "$mac_addr" == "Desconocida" ]]; then
        echo "No detectada"
        return
    fi

    local mac_lower
    mac_lower=$(echo "$mac_addr" | tr '[:upper:]' '[:lower:]')
    local ip_found=""

    # Método 1: Búsqueda en IP Neighbor / ARP
    ip_found=$(ip neighbor show | grep -i "$mac_lower" | awk '{print $1}' | head -n1)

    # Método 2: Tablas de concesión DHCP locales (dnsmasq / NetworkManager / systemd-networkd)
    if [[ -z "$ip_found" ]]; then
        local lease_files=(
            /var/lib/misc/dnsmasq.leases
            /var/lib/dhcp/dhcpd.leases
            /var/lib/NetworkManager/*.lease
            /var/lib/systemd/network/*.lease
        )
        for lf in "${lease_files[@]}"; do
            if [[ -f "$lf" ]]; then
                ip_found=$(grep -i "$mac_lower" "$lf" 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
                [[ -n "$ip_found" ]] && break
            fi
        done
    fi

    if [[ -n "$ip_found" ]]; then
        echo "$ip_found"
    else
        echo "No detectada (Offline/Buscando...)"
    fi
}

select_ram() {
    local CHOICE
    CHOICE=$(echo -e "1024 MB (1GB)\n2048 MB (2GB)\n4096 MB (4GB)\n8192 MB (8GB)\nPersonalizado..." | fzf --prompt="Seleccione Memoria RAM: ")
    case "$CHOICE" in
        *"1024"*) echo "1024" ;;
        *"2048"*) echo "2048" ;;
        *"4096"*) echo "4096" ;;
        *"8192"*) echo "8192" ;;
        *)
            read -rp "--> Introduce RAM personalizada en MB [2048]: " CUSTOM_RAM
            CUSTOM_RAM=$(echo "$CUSTOM_RAM" | tr -cd '0-9')
            echo "${CUSTOM_RAM:-2048}"
            ;;
    esac
}

select_cpus() {
    local CHOICE
    CHOICE=$(echo -e "1 CPU\n2 CPUs\n4 CPUs\n8 CPUs\nPersonalizado..." | fzf --prompt="Seleccione vCPUs: ")
    case "$CHOICE" in
        *"1 CPU"*) echo "1" ;;
        *"2 CPUs"*) echo "2" ;;
        *"4 CPUs"*) echo "4" ;;
        *"8 CPUs"*) echo "8" ;;
        *)
            read -rp "--> Introduce vCPUs personalizadas [2]: " CUSTOM_CPUS
            CUSTOM_CPUS=$(echo "$CUSTOM_CPUS" | tr -cd '0-9')
            echo "${CUSTOM_CPUS:-2}"
            ;;
    esac
}

select_disk_size() {
    local CHOICE
    CHOICE=$(echo -e "10 GB (Ligero)\n20 GB (Estándar)\n40 GB (Medio)\n80 GB (Grande)\nPersonalizado..." | fzf --prompt="Seleccione Tamaño de Disco QCOW2: ")
    case "$CHOICE" in
        *"10 GB"*) echo "10" ;;
        *"20 GB"*) echo "20" ;;
        *"40 GB"*) echo "40" ;;
        *"80 GB"*) echo "80" ;;
        *)
            read -rp "--> Introduce tamaño de disco en GB [20]: " CUSTOM_DISK
            CUSTOM_DISK=$(echo "$CUSTOM_DISK" | tr -cd '0-9')
            echo "${CUSTOM_DISK:-20}"
            ;;
    esac
}

configure_network() {
    echo -e "\n\e[34m[+] Seleccione la arquitectura de red:\e[0m"
    NET_MODE=$(echo -e "1. Bridge Nativo (Layer 2 / Requiere Bridge local)\n2. User / NAT + Port Forwarding (No Root / Wi-Fi Restringido)" | fzf --prompt="Modo de Red: ")

    RAND_MAC=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

    if [[ "$NET_MODE" =~ "User" ]]; then
        read -rp "--> Redirecciones de puerto hostfwd (Ej: tcp::2222-:22,tcp::8080-:80): " FWD_RULES
        local FWD_STR=""
        if [[ -n "$FWD_RULES" ]]; then
            FWD_RULES=$(echo "$FWD_RULES" | tr -cd 'a-zA-Z0-9_,-:')
            IFS=',' read -ra ADDR <<< "$FWD_RULES"
            for i in "${ADDR[@]}"; do
                FWD_STR+=",hostfwd=$i"
            done
        fi
        NET_ARGS="-netdev user,id=net0${FWD_STR} -device virtio-net-pci,netdev=net0,mac=$RAND_MAC"
    else
        BRIDGES=$(get_bridge_interfaces)
        if [[ -z "$BRIDGES" ]]; then
            echo -e "\e[33m[!] No se detectaron interfaces 'bridge' activas.\e[0m"
            echo -e "\e[33m[!] Creando puerto puente por defecto 'br0' temporal con iproute2...\e[0m"
            sudo ip link add name br0 type bridge
            sudo ip link set dev br0 up
            SELECTED_BRIDGE="br0"
        else
            SELECTED_BRIDGE=$(echo "$BRIDGES" | fzf --prompt="Selecciona la interfaz Bridge: ")
        fi
        [[ -z "$SELECTED_BRIDGE" ]] && SELECTED_BRIDGE="br0"
        SELECTED_BRIDGE=$(sanitize_name "$SELECTED_BRIDGE")
        NET_ARGS="-netdev bridge,id=net0,br=$SELECTED_BRIDGE -device virtio-net-pci,netdev=net0,mac=$RAND_MAC"
    fi
}

create_vm() {
    show_logo
    echo -e "\e[33m--- Creación de Nueva Máquina Virtual (Pentesting) ---\e[0m\n"

    read -rp "--> Nombre de la VM: " RAW_NAME
    VM_NAME=$(sanitize_name "$RAW_NAME")
    if [[ -z "$VM_NAME" || -f "$VM_CONFIG_DIR/${VM_NAME}.sh" ]]; then
        echo -e "\e[31m[!] Nombre inválido o VM ya existente.\e[0m"
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

    VM_RAM=$(select_ram)
    VM_CPUS=$(select_cpus)

    DRIVE_ARGS=""
    CDROM_ARG=""

    if [[ "$IMAGE_PATH" == *.ova ]]; then
        local file_size
        file_size=$(stat -c%s "$IMAGE_PATH" 2>/dev/null || stat -f%z "$IMAGE_PATH")
        local req_space=$(( file_size * 3 ))
        if ! check_free_space "$VM_STORAGE_DIR" "$req_space"; then
            read -rp "Presiona Enter..."
            return
        fi

        echo -e "\n\e[34m[+] Extrayendo paquete OVA multi-disco...\e[0m"
        TMP_OVA_DIR=$(mktemp -d -t qemu4me-ova-XXXXXX)
        tar -xvf "$IMAGE_PATH" -C "$TMP_OVA_DIR"

        mapfile -t VMDK_FILES < <(find "$TMP_OVA_DIR" -type f -name "*.vmdk" | sort)
        if [ ${#VMDK_FILES[@]} -eq 0 ]; then
            echo -e "\e[31m[!] No se encontraron discos .vmdk en el OVA.\e[0m"
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
            DRIVE_ARGS+="-drive file=\"$target_qcow2\",if=virtio,format=qcow2 "
        done

        rm -rf "$TMP_OVA_DIR"
        TMP_OVA_DIR=""
    else
        DISK_SIZE=$(select_disk_size)
        local req_space=$(( DISK_SIZE * 1073741824 ))
        if ! check_free_space "$VM_STORAGE_DIR" "$req_space"; then
            read -rp "Presiona Enter..."
            return
        fi

        DISCO_PATH="$VM_STORAGE_DIR/${VM_NAME}.qcow2"
        echo -e "\e[34m[+] Creando disco QCOW2 blanco...\e[0m"
        qemu-img create -f qcow2 "$DISCO_PATH" "${DISK_SIZE}G"
        DRIVE_ARGS="-drive file=\"$DISCO_PATH\",if=virtio,format=qcow2"
        CDROM_ARG="-cdrom \"$IMAGE_PATH\" -boot order=d"
    fi

    configure_network

    DISPLAY_CHOICE=$(echo -e "Default GTK/SDL GUI (-display default)\nHeadless / Sin GUI (-display none)\nVNC Server :1 (-vnc :1)" | fzf --prompt="Selecciona el modo de pantalla: ")
    case "$DISPLAY_CHOICE" in
        *"Headless"*) DEFAULT_DISPLAY="-display none" ;;
        *"VNC"*)      DEFAULT_DISPLAY="-vnc :1" ;;
        *)            DEFAULT_DISPLAY="-display default" ;;
    esac

    MONITOR_SOCKET="$QMP_DIR/${VM_NAME}-monitor.sock"
    QMP_SOCKET="$QMP_DIR/${VM_NAME}-qmp.sock"

    VM_SCRIPT="$VM_CONFIG_DIR/${VM_NAME}.sh"
    cat <<EOF > "$VM_SCRIPT"
#!/usr/bin/env bash

# Limpiar sockets huérfanos antes de arrancar
rm -f "$MONITOR_SOCKET" "$QMP_SOCKET"

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
    -enable-kvm \\
    -name "$VM_NAME" \\
    -m $VM_RAM \\
    -smp $VM_CPUS \\
    \$SNAPSHOT_OPT \\
    $DRIVE_ARGS \\
    $CDROM_ARG \\
    $NET_ARGS \\
    -monitor unix:"$MONITOR_SOCKET",server,nowait \\
    -qmp unix:"$QMP_SOCKET",server,nowait \\
    -vga virtio \\
    \$DISPLAY_OPT
EOF

    chmod +x "$VM_SCRIPT"
    echo -e "\n\e[32m[✓] ¡VM '$VM_NAME' configurada correctamente!\e[0m"
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
        status_socket="\e[32mACTIVO (chmod 600)\e[0m"
    else
        status_socket="\e[31mINACTIVO / LIMPIO\e[0m"
    fi

    echo -e "  ├─ MAC: $mac"
    echo -e "  ├─ IP Asignada: \e[32m$vm_ip\e[0m"
    echo -e "  ├─ Hostfwd Activos: $hostfwd"
    echo -e "  ├─ Tamaño Disco Principal: $disk_size"
    echo -e "  └─ Socket QMP/Monitor: $status_socket"
    echo -e "\e[34m====================================================================\e[0m\n"
}

qmp_control_menu() {
    local vm_name="$1"
    local monitor_socket="$QMP_DIR/${vm_name}-monitor.sock"

    if [[ ! -S "$monitor_socket" ]]; then
        echo -e "\e[31m[!] El socket de monitor QEMU no está activo. ¿Está la VM en ejecución?\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    while true; do
        show_logo
        show_vm_header "$vm_name"
        echo -e "\e[33m--- Control Monitor QEMU (QMP/Monitor) ---\e[0m\n"
        CMD_CHOICE=$(echo -e "1. Pausar VM (stop)\n2. Reanudar VM (cont)\n3. Forzar Reinicio (system_reset)\n4. Generar Memory Dump\n5. Consola Monitor Interactiva\n6. Volver" | fzf --prompt="Comando QEMU: ")

        case "$CMD_CHOICE" in
            1*) send_qmp_cmd "$monitor_socket" "stop" ;;
            2*) send_qmp_cmd "$monitor_socket" "cont" ;;
            3*) send_qmp_cmd "$monitor_socket" "system_reset" ;;
            4*) 
                read -rp "--> Ruta para guardar el Dump de memoria: " DUMP_PATH
                send_qmp_cmd "$monitor_socket" "pmemsave 0 0x10000000 $DUMP_PATH"
                echo -e "\e[32m[✓] Comando de descarga de memoria enviado.\e[0m"
                read -rp "Presiona Enter..."
                ;;
            5*)
                echo -e "\e[34m[+] Conectando a la consola monitor QEMU. Usa Ctrl+C para salir.\e[0m"
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
    echo -e "\e[33m--- Atajos de Teclado y Acceso Rápido ---\e[0m\n"

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

    labels+=("Copiar comando de ejecucion QEMU directo")
    cmds+=("$script_path")

    local CHOICE
    CHOICE=$(printf "%s\n" "${labels[@]}" | fzf --prompt="Selecciona Acción Rápida: ")
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
    echo -e "\e[33m--- Exportar Bundle de VM (Lab Pentesting) ---\e[0m\n"

    local export_tar="$HOME/${vm_name}_bundle.tar.gz"
    echo -e "\e[34m[+] Empaquetando VM '$vm_name' en $export_tar...\e[0m"

    local files_to_pack=("$VM_CONFIG_DIR/${vm_name}.sh")
    for d in "$VM_STORAGE_DIR/${vm_name}"*.qcow2; do
        [[ -f "$d" ]] && files_to_pack+=("$d")
    done

    tar -czvf "$export_tar" "${files_to_pack[@]}"
    echo -e "\e[32m[✓] Bundle creado exitosamente: $export_tar\e[0m"
    read -rp "Presiona Enter..."
}

import_bundle() {
    show_logo
    echo -e "\e[33m--- Importar Bundle de VM (.tar.gz) ---\e[0m\n"

    read -rp "--> Ruta completa del archivo .tar.gz: " BUNDLE_PATH
    if [[ ! -f "$BUNDLE_PATH" ]]; then
        echo -e "\e[31m[!] El archivo especificado no existe.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    echo -e "\e[34m[+] Extrayendo bundle en el sistema local...\e[0m"
    tar -xzvf "$BUNDLE_PATH" -C /
    echo -e "\e[32m[✓] Importación completada. La VM ya está disponible en tu lista.\e[0m"
    read -rp "Presiona Enter..."
}

clone_vm() {
    show_logo
    echo -e "\e[33m--- Clonación Rápida de VMs (Linked Clones QCow2) ---\e[0m\n"

    local VMS=()
    while IFS= read -r file; do
        [[ -f "$file" ]] && VMS+=("$(basename "$file" .sh)")
    done < <(find "$VM_CONFIG_DIR" -name "*.sh" 2>/dev/null)

    if [ ${#VMS[@]} -eq 0 ]; then
        echo -e "\e[31m[!] No hay máquinas virtuales registradas.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    SRC_VM=$(printf "%s\n" "${VMS[@]}" | fzf --prompt="Selecciona VM Base (Origen): ")
    [[ -z "$SRC_VM" ]] && return

    SRC_DISK="$VM_STORAGE_DIR/${SRC_VM}.qcow2"
    if [[ ! -f "$SRC_DISK" ]]; then
        echo -e "\e[31m[!] El disco base de $SRC_VM no existe en $SRC_DISK\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    read -rp "--> Nombre del Nuevo Clon: " RAW_CLONE
    CLONE_NAME=$(sanitize_name "$RAW_CLONE")
    if [[ -z "$CLONE_NAME" || -f "$VM_CONFIG_DIR/${CLONE_NAME}.sh" ]]; then
        echo -e "\e[31m[!] Nombre de clon inválido o ya existente.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    CLONE_DISK="$VM_STORAGE_DIR/${CLONE_NAME}.qcow2"
    
    echo -e "\e[34m[+] Creando Linked Clone con Backing File QCOW2...\e[0m"
    qemu-img create -f qcow2 -b "$SRC_DISK" -F qcow2 "$CLONE_DISK"

    RAND_MAC=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    
    sed -e "s/-name \"$SRC_VM\"/-name \"$CLONE_NAME\"/g" \
        -e "s/${SRC_VM}.qcow2/${CLONE_NAME}.qcow2/g" \
        -e "s/mac=52:54:00:[0-9A-Fa-f:]*/mac=$RAND_MAC/g" \
        -e "s/${SRC_VM}-monitor.sock/${CLONE_NAME}-monitor.sock/g" \
        -e "s/${SRC_VM}-qmp.sock/${CLONE_NAME}-qmp.sock/g" \
        "$VM_CONFIG_DIR/${SRC_VM}.sh" > "$VM_CONFIG_DIR/${CLONE_NAME}.sh"

    chmod +x "$VM_CONFIG_DIR/${CLONE_NAME}.sh"
    echo -e "\e[32m[✓] ¡Clon vinculado '$CLONE_NAME' creado al instante!\e[0m"
    read -rp "Presiona Enter..."
}

attach_resources() {
    local vm_name="$1"
    local script_path="$VM_CONFIG_DIR/${vm_name}.sh"

    show_logo
    show_vm_header "$vm_name"
    echo -e "\e[33m--- Gestión de Discos e ISOs Secundarias ---\e[0m\n"
    RESOURCE_ACTION=$(echo -e "1. Adjuntar Disco Secundario QCOW2\n2. Adjuntar Imagen ISO (CDROM)\n3. Volver" | fzf --prompt="Acción: ")

    case "$RESOURCE_ACTION" in
        1*)
            read -rp "--> Nombre o identificador del disco extra: " DISK_LABEL
            DISK_LABEL=$(sanitize_name "$DISK_LABEL")
            SEC_SIZE=$(select_disk_size)
            SEC_DISK_PATH="$VM_STORAGE_DIR/${vm_name}-${DISK_LABEL}.qcow2"
            
            qemu-img create -f qcow2 "$SEC_DISK_PATH" "${SEC_SIZE}G"
            sed -i "/exec qemu-system-x86_64/a \    -drive file=\"$SEC_DISK_PATH\",if=virtio,format=qcow2 \\\\" "$script_path"
            echo -e "\e[32m[✓] Disco secundario añadido al script ejecutable.\e[0m"
            read -rp "Presiona Enter..."
            ;;
        2*)
            ISO_PATH=$(find "$ISO_SEARCH_DIR" -type f -name "*.iso" 2>/dev/null | fzf --prompt="Selecciona ISO Secundaria: ")
            if [[ -n "$ISO_PATH" ]]; then
                sed -i "/exec qemu-system-x86_64/a \    -drive file=\"$ISO_PATH\",media=cdrom \\\\" "$script_path"
                echo -e "\e[32m[✓] ISO asignada correctamente como CD-ROM secundario.\e[0m"
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
        echo -e "\e[31m[!] No se encontró el disco principal para instantáneas: $primary_disk\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    while true; do
        show_logo
        show_vm_header "$vm_name"
        echo -e "\e[33m--- Gestión de Snapshots ---\e[0m\n"
        
        SNAP_ACTION=$(echo -e "1. Crear Snapshot\n2. Listar Snapshots\n3. Restaurar Snapshot\n4. Eliminar Snapshot\n5. Volver" | fzf --prompt="Selecciona acción de Snapshot: ")

        case "$SNAP_ACTION" in
            1*)
                read -rp "--> Nombre del Snapshot: " RAW_SNAP
                SNAP_NAME=$(sanitize_name "$RAW_SNAP")
                if [[ -n "$SNAP_NAME" ]]; then
                    qemu-img snapshot -c "$SNAP_NAME" "$primary_disk"
                    echo -e "\e[32m[✓] Snapshot '$SNAP_NAME' creado correctamente.\e[0m"
                fi
                read -rp "Presiona Enter..."
                ;;
            2*)
                echo -e "\e[34m[+] Instantáneas en $primary_disk:\e[0m"
                qemu-img snapshot -l "$primary_disk" || echo "Sin snapshots."
                read -rp "Presiona Enter..."
                ;;
            3*)
                mapfile -t SNAPS < <(qemu-img snapshot -l "$primary_disk" | tail -n +3 | awk '{print $2}')
                if [ ${#SNAPS[@]} -eq 0 ]; then
                    echo -e "\e[31m[!] No hay snapshots disponibles.\e[0m"
                else
                    TARGET_SNAP=$(printf "%s\n" "${SNAPS[@]}" | fzf --prompt="Snapshot a restaurar: ")
                    if [[ -n "$TARGET_SNAP" ]]; then
                        qemu-img snapshot -a "$TARGET_SNAP" "$primary_disk"
                        echo -e "\e[32m[✓] Disco restaurado al snapshot '$TARGET_SNAP'.\e[0m"
                    fi
                fi
                read -rp "Presiona Enter..."
                ;;
            4*)
                mapfile -t SNAPS < <(qemu-img snapshot -l "$primary_disk" | tail -n +3 | awk '{print $2}')
                if [ ${#SNAPS[@]} -eq 0 ]; then
                    echo -e "\e[31m[!] No hay snapshots disponibles.\e[0m"
                else
                    TARGET_SNAP=$(printf "%s\n" "${SNAPS[@]}" | fzf --prompt="Snapshot a eliminar: ")
                    if [[ -n "$TARGET_SNAP" ]]; then
                        qemu-img snapshot -d "$TARGET_SNAP" "$primary_disk"
                        echo -e "\e[31m[✓] Snapshot '$TARGET_SNAP' eliminado.\e[0m"
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
        read -rp "Presiona Enter para continuar..."
        return
    fi

    SELECTED_VM=$(printf "%s\n" "${VMS[@]}" | fzf --prompt="Selecciona una VM: ")
    [[ -z "$SELECTED_VM" ]] && return

    while true; do
        show_logo
        show_vm_header "$SELECTED_VM"

        ACTION=$(echo -e "Arrancar (GUI)\nArrancar Sandbox / Read-Only (-snapshot)\nArrancar (VNC Server :1)\nArrancar (Headless / Sin GUI)\nAcceso Rapido / Copiar Comandos\nControl QMP / Monitor\nGestionar Snapshots\nAdjuntar Discos/ISOs\nExportar Bundle (.tar.gz)\nApagar Forzado (Kill)\nEliminar VM (Script + Discos)\nVolver" | fzf --prompt="Acción [$SELECTED_VM]: ")

        case "$ACTION" in
            *"Arrancar (GUI)"*)
                "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --gui &
                echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada con GUI.\e[0m"
                read -rp "Presiona Enter..."
                ;;
            *"Sandbox"*)
                "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --snapshot --gui &
                echo -e "\e[33m[✓] VM '$SELECTED_VM' iniciada en MODO SANDBOX (Cambios no se guardarán).\e[0m"
                read -rp "Presiona Enter..."
                ;;
            *"Arrancar (VNC"*)
                "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --vnc &
                echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada en modo VNC (Puerto 5901 / :1).\e[0m"
                read -rp "Presiona Enter..."
                ;;
            *"Arrancar (Headless"*)
                "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --headless &
                echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada en segundo plano (Headless).\e[0m"
                read -rp "Presiona Enter..."
                ;;
            *"Acceso Rapido"*)
                quick_access_menu "$SELECTED_VM"
                ;;
            *"Control QMP"*)
                qmp_control_menu "$SELECTED_VM"
                ;;
            *"Snapshots"*)
                manage_snapshots "$SELECTED_VM"
                ;;
            *"Adjuntar"*)
                attach_resources "$SELECTED_VM"
                ;;
            *"Exportar"*)
                export_bundle "$SELECTED_VM"
                ;;
            *"Apagar"*)
                if pkill -f "qemu-system-x86_64.*-name $SELECTED_VM"; then
                    echo -e "\e[33m[!] Proceso QEMU finalizado.\e[0m"
                    rm -f "$QMP_DIR/${SELECTED_VM}"*.sock
                else
                    echo -e "\e[31m[!] La VM no estaba en ejecución.\e[0m"
                fi
                read -rp "Presiona Enter..."
                ;;
            *"Eliminar"*)
                read -rp "¿Confirmas eliminar '$SELECTED_VM' y TODOS sus discos asociados? (s/N): " CONF
                if [[ "$CONF" =~ ^[Ss]$ ]]; then
                    pkill -f "qemu-system-x86_64.*-name $SELECTED_VM" 2>/dev/null || true
                    rm -f "$VM_CONFIG_DIR/${SELECTED_VM}.sh"
                    rm -f "$VM_STORAGE_DIR/${SELECTED_VM}"*.qcow2
                    rm -f "$QMP_DIR/${SELECTED_VM}"*.sock
                    echo -e "\e[31m[✓] VM y discos asociados eliminados.\e[0m"
                    read -rp "Presiona Enter..."
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
        show_logo
        MENU_OPTION=$(echo -e "1. Crear nueva VM vulnerable (ISO / OVA)\n2. Gestionar / Listar VMs\n3. Clonar VM Rápida (Linked Clone)\n4. Importar Bundle de VM (.tar.gz)\n5. Salir" | fzf --prompt="Selecciona: ")
        case "$MENU_OPTION" in
            1*) create_vm ;;
            2*) manage_vms ;;
            3*) clone_vm ;;
            4*) import_bundle ;;
            5*) exit 0 ;;
            *) exit 0 ;;
        esac
    done
}

main_menu