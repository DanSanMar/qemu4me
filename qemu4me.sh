#!/usr/bin/env bash

# ==============================================================================
#  qemu4me - Generador y gestor interactivo de VM con XML nativo (Multi-distro)
# ==============================================================================

set -eo pipefail

# Obtener el HOME del usuario real que ejecuta sudo
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo "~$REAL_USER")

VM_DIR="/var/lib/libvirt/images"
ISO_SEARCH_DIR="$REAL_HOME"
TMP_XML=""
TMP_OVA_DIR=""

cleanup() {
    tput cnorm 2>/dev/null || true
    [[ -n "$TMP_XML" && -f "$TMP_XML" ]] && rm -f "$TMP_XML"
    [[ -n "$TMP_OVA_DIR" && -d "$TMP_OVA_DIR" ]] && rm -rf "$TMP_OVA_DIR"
}
trap cleanup EXIT SIGINT SIGTERM

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
    echo -e "\e[33m         -- CLI Interactive VM Manager for Pentesting --\e[0m\n"
}

# --- Detección de Gestor de Paquetes ---
check_and_install_dependencies() {
    local MISSING_BINS=()
    local REQUIRED_BINS=("virsh" "qemu-img" "fzf" "gawk" "tar")

    for bin in "${REQUIRED_BINS[@]}"; do
        if ! command -v "$bin" &>/dev/null; then
            MISSING_BINS+=("$bin")
        fi
    done

    if [ ${#MISSING_BINS[@]} -gt 0 ]; then
        echo -e "\e[31m[!] Faltan herramientas necesarias: ${MISSING_BINS[*]}\e[0m"
        read -rp "¿Deseas instalarlas automáticamente? (S/n): " CONFIRM
        CONFIRM=${CONFIRM:-S}

        if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
            if command -v pacman &>/dev/null; then
                sudo pacman -Sy --needed --noconfirm qemu-desktop libvirt dnsmasq iptables-nft edk2-ovmf fzf gawk tar
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y qemu-kvm libvirt edk2-ovmf fzf gawk tar
            elif command -v apt-get &>/dev/null; then
                sudo apt update && sudo apt install -y qemu-system-x86 qemu-utils libvirt-daemon-system ovmf fzf gawk tar
            else
                echo -e "\e[31m[!] Gestor de paquetes no soportado.\e[0m"
                exit 1
            fi
        else
            exit 1
        fi
    fi

    # Asegurar servicio libvirtd
    if ! systemctl is-active --quiet libvirtd && ! systemctl is-active --quiet virtqemud; then
        echo -e "\e[33m[!] Activando servicio de virtualización...\e[0m"
        sudo systemctl enable --now libvirtd 2>/dev/null || sudo systemctl enable --now virtqemud 2>/dev/null
    fi
}

create_vm() {
    show_logo
    echo -e "\e[33m--- Creación de Nueva Máquina Virtual ---\e[0m\n"

    read -rp "--> Nombre de la VM: " VM_NAME
    if [[ -z "$VM_NAME" ]]; then
        echo -e "\e[31m[!] El nombre no puede estar vacío.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
        echo -e "\e[31m[!] Ya existe una VM con el nombre '$VM_NAME'.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    echo -e "\n\e[34m[+] Buscando imágenes (.iso/.ova) en $ISO_SEARCH_DIR...\e[0m"
    IMAGE_PATH=$(find "$ISO_SEARCH_DIR" -type f \( -name "*.iso" -o -name "*.ova" \) 2>/dev/null | fzf --prompt="Selecciona la ISO u OVA: ")

    if [[ -z "$IMAGE_PATH" ]]; then
        echo -e "\e[31m[!] No se seleccionó ninguna imagen.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    read -rp "--> Memoria RAM en MB [2048]: " VM_RAM
    VM_RAM=${VM_RAM:-2048}

    read -rp "--> Número de vCPUs [2]: " VM_CPUS
    VM_CPUS=${VM_CPUS:-2}

    if [[ "$IMAGE_PATH" == *.iso ]]; then
        read -rp "--> Tamaño del disco qcow2 en GB [20]: " DISK_SIZE
        DISK_SIZE=${DISK_SIZE:-20}
    fi

    echo -e "\n\e[34m[+] Selecciona el modo de red:\e[0m"
    NET_TYPE=$(echo -e "NAT (Red predeterminada Libvirt)\nBridge (Macvtap directo a la interfaz)\nAislada (Host-Only)" | fzf --prompt="Tipo de Red: ")

    case "$NET_TYPE" in
        *"Bridge"*)
            PHYS_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | fzf --prompt="Interfaz física: ")
            if [[ -z "$PHYS_IFACE" ]]; then return; fi
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
        *) return ;;
    esac

    DISCO_PATH="$VM_DIR/${VM_NAME}.qcow2"
    TMP_XML="/tmp/${VM_NAME}.xml"
    sudo mkdir -p "$VM_DIR"

    # --- Procesamiento ISO vs OVA ---
    if [[ "$IMAGE_PATH" == *.ova ]]; then
        echo -e "\n\e[34m[+] Descomprimiendo paquete OVA...\e[0m"
        TMP_OVA_DIR=$(mktemp -d -t qemu4me-ova-XXXXXX)
        tar -xf "$IMAGE_PATH" -C "$TMP_OVA_DIR"

        VMDK_FILE=$(find "$TMP_OVA_DIR" -type f -name "*.vmdk" | head -n 1)

        if [[ -z "$VMDK_FILE" ]]; then
            echo -e "\e[31m[!] No se encontró ningún disco .vmdk dentro del paquete .ova.\e[0m"
            read -rp "Presiona Enter..."
            return
        fi

        echo -e "\e[34m[+] Convirtiendo VMDK a QCOW2...\e[0m"
        sudo qemu-img convert -f vmdk -O qcow2 "$VMDK_FILE" "$DISCO_PATH"

        rm -rf "$TMP_OVA_DIR"
        TMP_OVA_DIR=""

        CDROM_XML=""
        BOOT_DEVS="<boot dev='hd'/>"
    else
        echo -e "\n\e[34m[+] Creando disco virtual de ${DISK_SIZE}GB...\e[0m"
        sudo qemu-img create -f qcow2 "$DISCO_PATH" "${DISK_SIZE}G"

        CDROM_XML="<disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${IMAGE_PATH}'/>
      <target dev='sdb' bus='sata'/>
      <readonly/>
    </disk>"
        BOOT_DEVS="<boot dev='cdrom'/><boot dev='hd'/>"
    fi

    # Detección dinámica de la ruta del emulador en el Host
    QEMU_EMULATOR=$(command -v qemu-system-x86_64 || echo "/usr/bin/qemu-system-x86_64")
    RAM_KIB=$((VM_RAM * 1024))

    # Plantilla XML Robusta
    cat <<EOF > "$TMP_XML"
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='KiB'>${RAM_KIB}</memory>
  <vcpu placement='static'>${VM_CPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    ${BOOT_DEVS}
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <devices>
    <emulator>${QEMU_EMULATOR}</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISCO_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    ${CDROM_XML}
    ${NET_XML}
    <input type='tablet' bus='usb'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video>
      <model type='qxl'/>
    </video>
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

    echo -e "\n\e[32m[✓] ¡Máquina virtual '${VM_NAME}' iniciada correctamente!\e[0m"
    echo -e "Puerto VNC asignado: \e[36msudo virsh vncdisplay ${VM_NAME}\e[0m"
    read -rp "Presiona Enter para volver..."
}

manage_vms() {
    show_logo
    echo -e "\e[33m--- Gestión de Máquinas Virtuales ---\e[0m\n"

    VMS=$(sudo virsh list --all --name | grep -v '^$')

    if [[ -z "$VMS" ]]; then
        echo -e "\e[31m[!] No hay máquinas virtuales registradas.\e[0m"
        read -rp "Presiona Enter..."
        return
    fi

    SELECTED_VM=$(echo "$VMS" | fzf --prompt="Selecciona una VM: ")
    [[ -z "$SELECTED_VM" ]] && return

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
            read -rp "¿ESTÁS SEGURO de borrar '$SELECTED_VM' y su disco? (s/N): " DEL_CONFIRM
            if [[ "$DEL_CONFIRM" =~ ^[Ss]$ ]]; then
                sudo virsh destroy "$SELECTED_VM" 2>/dev/null || true
                sudo virsh undefine "$SELECTED_VM"
                if [[ -f "$VM_DIR/${SELECTED_VM}.qcow2" ]]; then
                    sudo rm -f "$VM_DIR/${SELECTED_VM}.qcow2"
                fi
                echo -e "\e[31m[✓] VM '$SELECTED_VM' y su disco han sido eliminados.\e[0m"
            fi
            ;;
        *) return ;;
    esac

    read -rp "Presiona Enter..."
}

main_menu() {
    check_and_install_dependencies

    while true; do
        show_logo
        MENU_OPTION=$(echo -e "1. Crear nueva VM (ISO / OVA)\n2. Gestionar / Listar VMs\n3. Salir" | fzf --prompt="Selecciona una opción: ")

        case "$MENU_OPTION" in
            1*) create_vm ;;
            2*) manage_vms ;;
            3*|"") 
                echo -e "\e[32m¡Hasta luego!\e[0m"
                exit 0 
                ;;
        esac
    done
}

main_menu