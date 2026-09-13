#!/usr/bin/env bash

# ==============================================================================
#  qemu4me - Generador y gestor interactivo de Máquinas Virtuales para QEMU/KVM
# ==============================================================================

set -e

# Directorios y rutas por defecto
VM_DIR="/var/lib/libvirt/images"
ISO_SEARCH_DIR="$HOME"
TMP_XML=""

# Lista de paquetes del sistema necesarios
REQUIRED_PACKAGES=(
    "qemu-desktop"
    "libvirt"
    "dnsmasq"
    "iptables-nft"
    "edk2-ovmf"
    "fzf"
    "gawk"
)

# ==============================================================================
#  Trap de Limpieza y Salida
# ==============================================================================
cleanup() {
    # Restaurar cursor por si fzf o una interrupción lo ocultó
    tput cnorm 2>/dev/null || true
    
    # Eliminar XML temporal si existe
    if [[ -n "$TMP_XML" && -f "$TMP_XML" ]]; then
        rm -f "$TMP_XML"
    fi
}

# Capturar Ctrl+C (SIGINT), SIGTERM y la salida del script (EXIT)
trap 'cleanup' EXIT SIGINT SIGTERM

# Función para mostrar el logo
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
    echo -e "\e[33m         -- CLI Interactive VM Builder for Pentesting --\e[0m\n"
}

# ==============================================================================
#  Módulo de comprobación e instalación de dependencias
# ==============================================================================
check_and_install_dependencies() {
    echo -e "\e[34m[+] Comprobando dependencias del sistema...\e[0m"
    local MISSING_PACKAGES=()

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            MISSING_PACKAGES+=("$pkg")
        fi
    done

    if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
        echo -e "\n\e[31m[!] Se detectaron paquetes faltantes en el sistema:\e[0m"
        for missing in "${MISSING_PACKAGES[@]}"; do
            echo -e "    \e[33m- $missing\e[0m"
        done
        echo ""
        read -rp "¿Deseas instalarlos ahora con pacman? (S/n): " INSTALL_CONFIRM
        INSTALL_CONFIRM=${INSTALL_CONFIRM:-S}

        if [[ "$INSTALL_CONFIRM" =~ ^[Ss]$ ]]; then
            echo -e "\n\e[34m[+] Instalando dependencias con pacman...\e[0m"
            sudo pacman -S --needed "${MISSING_PACKAGES[@]}"
            echo -e "\e[32m[✓] Dependencias instaladas correctamente.\e[0m\n"
        else
            echo -e "\e[31m[!] No se instalaron las dependencias requeridas. Cancelando ejecución.\e[0m"
            exit 1
        fi
    else
        echo -e "\e[32m[✓] Todos los paquetes necesarios están instalados.\e[0m\n"
    fi

    # Verificar que el servicio libvirtd esté activo
    if ! systemctl is-active --quiet libvirtd; then
        echo -e "\e[33m[!] El servicio libvirtd no está activo. Iniciando...\e[0m"
        sudo systemctl enable --now libvirtd.service
    fi
}

# ==============================================================================
#  Módulo: Crear Nueva VM
# ==============================================================================
create_vm() {
    show_logo
    echo -e "\e[33m--- Creación de Nueva Máquina Virtual ---\e[0m\n"

    # 1. Nombre de la máquina virtual
    read -rp "--> Introduce el nombre de la VM: " VM_NAME
    if [[ -z "$VM_NAME" ]]; then
        echo -e "\e[31m[!] El nombre no puede estar vacío.\e[0m"
        read -rp "Presiona Enter para continuar..."
        return
    fi

    # 2. Buscar imagen ISO usando fzf
    echo -e "\n\e[34m[+] Buscando archivos .iso en $ISO_SEARCH_DIR...\e[0m"
    ISO_PATH=$(find "$ISO_SEARCH_DIR" -type f -name "*.iso" 2>/dev/null | fzf --prompt="Selecciona la ISO de instalación: ")

    if [[ -z "$ISO_PATH" ]]; then
        echo -e "\e[31m[!] No se seleccionó ninguna ISO.\e[0m"
        read -rp "Presiona Enter para continuar..."
        return
    fi
    echo -e "\e[32m[✓] ISO Seleccionada:\e[0m $ISO_PATH"

    # 3. Asignación de RAM (en MB)
    read -rp "--> Memoria RAM en MB [Por defecto: 2048]: " VM_RAM
    VM_RAM=${VM_RAM:-2048}

    # 4. Asignación de vCPUs
    read -rp "--> Número de vCPUs [Por defecto: 2]: " VM_CPUS
    VM_CPUS=${VM_CPUS:-2}

    # 5. Tamaño del disco duro (en GB)
    read -rp "--> Tamaño del disco qcow2 en GB [Por defecto: 20]: " DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-20}

    # 6. Selección del tipo de red usando fzf
    echo -e "\n\e[34m[+] Selecciona el modo de red:\e[0m"
    NET_TYPE=$(echo -e "Bridge (Macvtap directo a la interfaz del Host)\nNAT (Red predeterminada de Libvirt)\nAislada (Host-Only)" | fzf --prompt="Tipo de Red: ")

    case "$NET_TYPE" in
        *"Bridge"*)
            echo -e "\n\e[34m[+] Selecciona la interfaz física de red para el Bridge:\e[0m"
            PHYS_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | fzf --prompt="Interfaz física: ")
            if [[ -z "$PHYS_IFACE" ]]; then
                echo -e "\e[31m[!] No se seleccionó interfaz.\e[0m"
                read -rp "Presiona Enter para continuar..."
                return
            fi
            NET_XML="<interface type='direct'>
      <source dev='$PHYS_IFACE' mode='bridge'/>
      <model type='virtio'/>
    </interface>"
            ;;
        *"NAT"*)
            NET_XML="<interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>"
            ;;
        *"Aislada"*)
            NET_XML="<interface type='network'>
      <source network='isolated'/>
      <model type='virtio'/>
    </interface>"
            ;;
        *)
            echo -e "\e[31m[!] Opción de red inválida.\e[0m"
            read -rp "Presiona Enter para continuar..."
            return
            ;;
    esac

    # 7. Resumen de configuración
    show_logo
    echo -e "\e[33m=== Resumen de Configuración ===\e[0m"
    echo -e "Nombre VM  : $VM_NAME"
    echo -e "RAM        : ${VM_RAM} MB"
    echo -e "vCPUs      : $VM_CPUS"
    echo -e "Disco      : ${DISK_SIZE} GB ($VM_DIR/${VM_NAME}.qcow2)"
    echo -e "Red        : $NET_TYPE"
    echo -e "ISO        : $ISO_PATH"
    echo -e "================================\n"

    read -rp "¿Deseas crear y lanzar la máquina virtual? (S/n): " CONFIRM
    CONFIRM=${CONFIRM:-S}
    if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
        echo -e "\e[31m[!] Operación cancelada.\e[0m"
        read -rp "Presiona Enter para continuar..."
        return
    fi

    # --- Proceso de Creación ---
    DISCO_PATH="$VM_DIR/${VM_NAME}.qcow2"
    TMP_XML="/tmp/${VM_NAME}.xml"

    sudo mkdir -p "$VM_DIR"

    echo -e "\n\e[34m[+] Creando disco virtual qcow2...\e[0m"
    sudo qemu-img create -f qcow2 "$DISCO_PATH" "${DISK_SIZE}G"

    RAM_KIB=$((VM_RAM * 1024))

    cat <<EOF > "$TMP_XML"
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='KiB'>${RAM_KIB}</memory>
  <vcpu placement='static'>${VM_CPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='cdrom'/>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISCO_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${ISO_PATH}'/>
      <target dev='hdb' bus='ide'/>
    </disk>
    ${NET_XML}
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <console type='pty'/>
  </devices>
</domain>
EOF

    echo -e "\e[34m[+] Registrando la VM en Libvirt...\e[0m"
    sudo virsh define "$TMP_XML"
    rm -f "$TMP_XML"
    TMP_XML=""

    echo -e "\e[34m[+] Arrancando la VM ${VM_NAME}...\e[0m"
    sudo virsh start "$VM_NAME"

    echo -e "\n\e[32m[✓] ¡Máquina virtual '${VM_NAME}' creada y lanzada correctamente!\e[0m"
    echo -e "Puerto VNC asignado: \e[36msudo virsh vncdisplay ${VM_NAME}\e[0m"
    read -rp "Presiona Enter para volver al menú..."
}

# ==============================================================================
#  Módulo: Gestionar VMs Existentes
# ==============================================================================
manage_vms() {
    show_logo
    echo -e "\e[33m--- Gestión de Máquinas Virtuales ---\e[0m\n"

    # Obtener lista de VMs registradas
    VMS=$(sudo virsh list --all --name | grep -v '^$')

    if [[ -z "$VMS" ]]; then
        echo -e "\e[31m[!] No hay máquinas virtuales registradas en Libvirt.\e[0m"
        read -rp "Presiona Enter para continuar..."
        return
    fi

    SELECTED_VM=$(echo "$VMS" | fzf --prompt="Selecciona una VM: ")

    if [[ -z "$SELECTED_VM" ]]; then
        return
    fi

    ACTION=$(echo -e "Arrancar (Start)\nApagar (Shutdown)\nForzar Apagado (Destroy)\nEliminar VM (Undefine + Borrar Disco)\nVolver" | fzf --prompt="Acción para [$SELECTED_VM]: ")

    case "$ACTION" in
        *"Arrancar"*)
            sudo virsh start "$SELECTED_VM"
            echo -e "\e[32m[✓] VM '$SELECTED_VM' iniciada.\e[0m"
            ;;
        *"Apagar"*)
            sudo virsh shutdown "$SELECTED_VM"
            echo -e "\e[33m[!] Orden de apagado enviada a '$SELECTED_VM'.\e[0m"
            ;;
        *"Forzar"*)
            sudo virsh destroy "$SELECTED_VM"
            echo -e "\e[31m[!] VM '$SELECTED_VM' forzada a apagar.\e[0m"
            ;;
        *"Eliminar"*)
            read -rp "¿ESTÁS SEGURO de borrar la VM '$SELECTED_VM' y su disco? (s/N): " DEL_CONFIRM
            if [[ "$DEL_CONFIRM" =~ ^[Ss]$ ]]; then
                sudo virsh destroy "$SELECTED_VM" 2>/dev/null || true
                sudo virsh undefine "$SELECTED_VM"
                if [[ -f "$VM_DIR/${SELECTED_VM}.qcow2" ]]; then
                    sudo rm -f "$VM_DIR/${SELECTED_VM}.qcow2"
                fi
                echo -e "\e[31m[✓] VM '$SELECTED_VM' y su disco han sido eliminados.\e[0m"
            fi
            ;;
        *)
            return
            ;;
    esac

    read -rp "Presiona Enter para continuar..."
}

# ==============================================================================
#  Bucle del Menú Principal
# ==============================================================================
main_menu() {
    check_and_install_dependencies

    while true; do
        show_logo
        MENU_OPTION=$(echo -e "1. Crear nueva VM\n2. Gestionar / Listar VMs\n3. Salir" | fzf --prompt="Selecciona una opción: ")

        case "$MENU_OPTION" in
            1*)
                create_vm
                ;;
            2*)
                manage_vms
                ;;
            3*)
                echo -e "\e[32m¡Hasta luego!\e[0m"
                exit 0
                ;;
            *)
                echo -e "\e[32mSaliendo...\e[0m"
                exit 0
                ;;
        esac
    done
}

# Ejecutar menú principal
main_menu