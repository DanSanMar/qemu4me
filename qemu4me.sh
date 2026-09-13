#!/usr/bin/env bash

# ==============================================================================
#  qemu4me - Gestor ultraligero de VMs para Pentesting (QEMU Nativo)
# ==============================================================================

set -eo pipefail

CONFIG_DIR="$HOME/.config/qemu4me"
VM_STORAGE_DIR="$CONFIG_DIR/disks"
VM_CONFIG_DIR="$CONFIG_DIR/vms"
QMP_DIR="$CONFIG_DIR/qmp"
ISO_SEARCH_DIR="$HOME"
TMP_OVA_DIR=""

mkdir -p "$VM_STORAGE_DIR" "$VM_CONFIG_DIR" "$QMP_DIR"

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
    echo -e "\e[33m         -- CLI VM Manager for Pentesting (Pure QEMU + QMP) --\e[0m\n"
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
            for pkg in qemu-desktop fzf gawk tar iproute2 openbsd-netcat; do
                pacman -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Arch...\e[0m"
                sudo pacman -S --needed --noconfirm "${MISSING[@]}"
            fi
            ;;
        fedora)
            for pkg in qemu-kvm fzf gawk tar iproute nc; do
                rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Fedora...\e[0m"
                sudo dnf install -y "${MISSING[@]}"
            fi
            ;;
        debian)
            for pkg in qemu-system-x86 fzf gawk tar iproute2 netcat-openbsd; do
                dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
            done
            if [ ${#MISSING[@]} -gt 0 ]; then
                echo -e "\e[34m[+] Instalando dependencias en Debian/Ubuntu...\e[0m"
                sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"
            fi
            ;;
    esac

    if [[ ! -f /etc/qemu/bridge.conf ]]; then
        echo -e "\e[33m[!] Configurando /etc/qemu/bridge.conf para el modo bridge...\e[0m"
        sudo mkdir -p /etc/qemu
        echo "allow all" | sudo tee /etc/qemu/bridge.conf >/dev/null
        sudo chmod 640 /etc/qemu/bridge.conf
    fi

    if ! lsmod | grep -q kvm; then
        sudo modprobe kvm 2>/dev/null || true
        sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    fi
}

get_bridge_interfaces() {
    ip -d link show type bridge | grep -E '^[0-9]+:' | awk -F': ' '{print $2}'
}

configure_network() {
    echo -e "\n\e[34m[+] Seleccione la arquitectura de red:\e[0m"
    NET_MODE=$(echo -e "1. Bridge Nativo (Layer 2 / Requiere Bridge local)\n2. User / NAT + Port Forwarding (No Root / Wi-Fi Restringido)" | fzf --prompt="Modo de Red: ")

    RAND_MAC=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

    if [[ "$NET_MODE" =~ "User" ]]; then
        read -rp "--> Redirecciones de puerto hostfwd (Ejemplo: tcp::2222-:22,tcp::8080-:80): " FWD_RULES
        if [[ -n "$FWD_RULES" ]]; then
            # Formatear reglas
            IFS=',' read -ra ADDR <<< "$FWD_RULES"
            local FWD_STR=""
            for i in "${ADDR[@]}"; do
                FWD_STR+=",hostfwd=$i"
            done
            NET_ARGS="-netdev user,id=net0${FWD_STR} -device virtio-net-pci,netdev=net0,mac=$RAND_MAC"
        else
            NET_ARGS="-netdev user,id=net0 -device virtio-net-pci,netdev=net0,mac=$RAND_MAC"
        fi
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
        NET_ARGS="-netdev bridge,id=net0,br=$SELECTED_BRIDGE -device virtio-net-pci,netdev=net0,mac=$RAND_MAC"
    fi
}

create_vm() {
    show_logo
    echo -e "\e[33m--- Creación de Nueva Máquina Virtual (Pentesting) ---\e[0m\n"

    read -rp "--> Nombre de la VM: " RAW_NAME
    VM_NAME=$(echo "$RAW_NAME" | tr -cd 'a-zA-Z0-9_-')
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

    read -rp "--> Memoria RAM en MB [2048]: " VM_RAM; VM_RAM=${VM_RAM:-2048}
    read -rp "--> vCPUs [2]: " VM_CPUS; VM_CPUS=${VM_CPUS:-2}

    DRIVE_ARGS=""
    CDROM_ARG=""

    if [[ "$IMAGE_PATH" == *.ova ]]; then
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
            target_qcow2=("$idx" -eq 0) && target_qcow2="$VM_STORAGE_DIR/${VM_NAME}.qcow2" || target_qcow2="$VM_STORAGE_DIR/${VM_NAME}-disk${idx}.qcow2"
            echo -e "  └─ Convirtiendo ($((idx+1))/${#VMDK_FILES[@]}): $(basename "$vmdk") -> $(basename "$target_qcow2")"
            qemu-img convert -f vmdk -O qcow2 "$vmdk" "$target_qcow2"
            DRIVE_ARGS+="-drive file=\"$target_qcow2\",if=virtio,format=qcow2 "
        done

        rm -rf "$TMP_OVA_DIR"
        TMP_OVA_DIR=""
    else
        DISCO_PATH="$VM_STORAGE_DIR/${VM_NAME}.qcow2"
        read -rp "--> Tamaño del disco en GB [20]: " DISK_SIZE; DISK_SIZE=${DISK_SIZE:-20}
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

DISPLAY_OPT="$DEFAULT_DISPLAY"
for arg in "\$@"; do
    case \$arg in
        --vnc) DISPLAY_OPT="-vnc :1" ;;
        --headless) DISPLAY_OPT="-display none" ;;
        --gui) DISPLAY_OPT="-display default" ;;
    esac
done

exec qemu-system-x86_64 \\
    -enable-kvm \\
    -name "$VM_NAME" \\
    -m $VM_RAM \\
    -smp $VM_CPUS \\
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
        echo -e "\e[33m--- Control Monitor QEMU (QMP/Monitor): $vm_name ---\e[0m\n"
        CMD_CHOICE=$(echo -e "1. Pausar VM (stop)\n2. Reanudar VM (cont)\n3. Forzar Reinicio (system_reset)\n4. Generar Memory Dump\n5. Consola Monitor Interactiva\n6. Volver" | fzf --prompt="Comando QEMU: ")

        case "$CMD_CHOICE" in
            1*) echo "stop" | nc -U "$monitor_socket" ;;
            2*) echo "cont" | nc -U "$monitor_socket" ;;
            3*) echo "system_reset" | nc -U "$monitor_socket" ;;
            4*) 
                read -rp "--> Ruta para guardar el Dump de memoria: " DUMP_PATH
                echo "pmemsave 0 0x10000000 $DUMP_PATH" | nc -U "$monitor_socket"
                echo -e "\e[32m[✓] Comando enviado.\e[0m"
                read -rp "Presiona Enter..."
                ;;
            5*)
                echo -e "\e[34m[+] Conectando a la consola monitor QEMU. Usa Ctrl+C para salir.\e[0m"
                nc -U "$monitor_socket" || true
                ;;
            *) break ;;
        esac
    done
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
    CLONE_NAME=$(echo "$RAW_CLONE" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$CLONE_NAME" || -f "$VM_CONFIG_DIR/${CLONE_NAME}.sh" ]]; then
        echo -e "\e[31m[!] Nombre de clon inválido o ya existente.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    CLONE_DISK="$VM_STORAGE_DIR/${CLONE_NAME}.qcow2"
    
    echo -e "\e[34m[+] Creando Linked Clone con Backing File QCOW2...\e[0m"
    qemu-img create -f qcow2 -b "$SRC_DISK" -F qcow2 "$CLONE_DISK"

    # Duplicar y ajustar script ejecutable
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
    echo -e "\e[33m--- Gestión de Discos e ISOs Secundarias: $vm_name ---\e[0m\n"
    RESOURCE_ACTION=$(echo -e "1. Adjuntar Disco Secundario QCOW2\n2. Adjuntar Imagen ISO (CDROM)\n3. Volver" | fzf --prompt="Acción: ")

    case "$RESOURCE_ACTION" in
        1*)
            read -rp "--> Nombre o identificador del disco extra: " DISK_LABEL
            read -rp "--> Tamaño en GB [10]: " SEC_SIZE; SEC_SIZE=${SEC_SIZE:-10}
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
        echo -e "\e[33m--- Gestión de Snapshots: $vm_name ---\e[0m\n"
        
        SNAP_ACTION=$(echo -e "1. Crear Snapshot\n2. Listar Snapshots\n3. Restaurar Snapshot\n4. Eliminar Snapshot\n5. Volver" | fzf --prompt="Selecciona acción de Snapshot: ")

        case "$SNAP_ACTION" in
            1*)
                read -rp "--> Nombre del Snapshot: " RAW_SNAP
                SNAP_NAME=$(echo "$RAW_SNAP" | tr -cd 'a-zA-Z0-9_-')
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

    if pgrep -f "qemu-system-x86_64.*-name $SELECTED_VM" > /dev/null; then
        STATUS="\e[32m[EN EJECUCIÓN]\e[0m"
    else
        STATUS="\e[31m[APAGADA]\e[0m"
    fi

    echo -e "Estado de $SELECTED_VM: $STATUS\n"
    ACTION=$(echo -e "Arrancar (GUI)\nArrancar (VNC Server :1)\nArrancar (Headless / Sin GUI)\nControl QMP / Monitor\nGestionar Snapshots\nAdjuntar Discos/ISOs\nApagar Forzado (Kill)\nEliminar VM (Script + Discos)\nVolver" | fzf --prompt="Acción [$SELECTED_VM]: ")

    case "$ACTION" in
        *"Arrancar (GUI)"*)
            "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --gui &
            echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada con GUI.\e[0m"
            ;;
        *"Arrancar (VNC"*)
            "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --vnc &
            echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada en modo VNC (Puerto 5901 / :1).\e[0m"
            ;;
        *"Arrancar (Headless"*)
            "$VM_CONFIG_DIR/${SELECTED_VM}.sh" --headless &
            echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada en segundo plano (Headless).\e[0m"
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
        *"Apagar"*)
            if pkill -f "qemu-system-x86_64.*-name $SELECTED_VM"; then
                echo -e "\e[33m[!] Proceso QEMU finalizado.\e[0m"
                rm -f "$QMP_DIR/${SELECTED_VM}"*.sock
            else
                echo -e "\e[31m[!] La VM no estaba en ejecución.\e[0m"
            fi
            ;;
        *"Eliminar"*)
            read -rp "¿Confirmas eliminar '$SELECTED_VM' y TODOS sus discos asociados? (s/N): " CONF
            if [[ "$CONF" =~ ^[Ss]$ ]]; then
                pkill -f "qemu-system-x86_64.*-name $SELECTED_VM" 2>/dev/null || true
                rm -f "$VM_CONFIG_DIR/${SELECTED_VM}.sh"
                rm -f "$VM_STORAGE_DIR/${SELECTED_VM}"*.qcow2
                rm -f "$QMP_DIR/${SELECTED_VM}"*.sock
                echo -e "\e[31m[✓] VM y discos asociados eliminados.\e[0m"
            fi
            ;;
    esac
    read -rp "Presiona Enter para continuar..."
}

main_menu() {
    check_and_install_dependencies
    while true; do
        show_logo
        MENU_OPTION=$(echo -e "1. Crear nueva VM vulnerable (ISO / OVA)\n2. Gestionar / Listar VMs\n3. Clonar VM Rápida (Linked Clone)\n4. Salir" | fzf --prompt="Selecciona: ")
        case "$MENU_OPTION" in
            1*) create_vm ;;
            2*) manage_vms ;;
            3*) clone_vm ;;
            4*) exit 0 ;;
            *) exit 0 ;;
        esac
    done
}

main_menu