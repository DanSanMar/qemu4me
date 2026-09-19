#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import subprocess
import shutil
import glob
from datetime import datetime

# ==============================================================================
#  lab4me.py - Gestor Automático, Autosuficiente y Autoreparable para CTF
# ==============================================================================

CONFIG_DIR = os.path.expanduser("~/.config/lab4me")
os.makedirs(CONFIG_DIR, exist_ok=True)

# Colores ANSI
RESET = "\033[0m"
AZUL_BRILLANTE = "\033[1;34m"
VERDE_BRILLANTE = "\033[1;32m"
AMARILLO_BRILLANTE = "\033[1;33m"
ROJO_BRILLANTE = "\033[1;31m"
BLANCO = "\033[97m"

def get_logo():
    hora = datetime.now().strftime("%H:%M:%S")
    return f"{VERDE_BRILLANTE}--- ⚡ LAB4ME (AUTO-REPAIR ENGINE) | {BLANCO}{hora}{VERDE_BRILLANTE} ⚡---{RESET}"

def clear_screen():
    os.system("clear" if os.name == "posix" else "cls")

def run_cmd(cmd, shell=True):
    try:
        subprocess.run(cmd, shell=shell, check=True)
        return True
    except subprocess.CalledProcessError:
        return False

def detect_distro():
    if os.path.exists("/etc/os-release"):
        with open("/etc/os-release") as f:
            content = f.read().lower()
            if "arch" in content:
                return "arch"
            elif "fedora" in content:
                return "fedora"
    return "debian"

def fzf_menu(options, prompt="Selecciona: "):
    fzf_input = "\n".join(options)
    cmd = f"fzf --prompt='{prompt}' --height=40% --reverse --border --ansi"
    process = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    stdout, _ = process.communicate(input=fzf_input)
    return stdout.strip()

def ensure_vbox_kernel():
    """Comprueba si el driver de VirtualBox está activo; si falla, lo repara automáticamente."""
    print(f"{AZUL_BRILLANTE}[+] Verificando estado del kernel de VirtualBox...{RESET}")
    
    # Intentar cargar el módulo directamente
    res = subprocess.run("sudo modprobe vboxdrv", shell=True, capture_output=True)
    if res.returncode == 0:
        print(f"{VERDE_BRILLANTE}[✓] El driver del kernel de VirtualBox está activo.{RESET}")
        return True

    print(f"{AMARILLO_BRILLANTE}[!] El driver del kernel (vboxdrv) no está activo o falta compilar.{RESET}")
    print(f"{AZUL_BRILLANTE}[+] Iniciando protocolo de autorreparación del sistema...{RESET}")
    
    distro = detect_distro()
    if distro == "arch":
        run_cmd("sudo pacman -Syu --needed --noconfirm dkms linux-headers virtualbox-host-dkms")
        run_cmd("sudo modprobe vboxdrv")
    else:
        # Ubuntu / Debian / Kali / Mint
        run_cmd("sudo apt-get update")
        run_cmd("sudo apt-get install -y dkms build-essential linux-headers-$(uname -r) virtualbox-dkms virtualbox-qt")
        # Forzar la reconfiguración limpia del módulo con vboxconfig si existe
        if os.path.exists("/sbin/vboxconfig"):
            run_cmd("sudo /sbin/vboxconfig")
        else:
            run_cmd("sudo dpkg-reconfigure virtualbox-dkms")
        run_cmd("sudo modprobe vboxdrv")

    # Verificación final post-reparación
    res_final = subprocess.run("sudo modprobe vboxdrv", shell=True, capture_output=True)
    if res_final.returncode == 0:
        print(f"{VERDE_BRILLANTE}[✓] Kernel de VirtualBox reparado y cargado con éxito.{RESET}")
        return True
    else:
        print(f"{ROJO_BRILLANTE}[!] Error crítico: No se pudo arrancar el módulo vboxdrv del kernel.{RESET}")
        print(f"{ROJO_BRILLANTE}[!] Asegúrate de que Secure Boot esté desactivado en tu BIOS/UEFI si causa bloqueos.{RESET}")
        input("Presiona Enter para continuar bajo tu propio riesgo...")
        return False

def check_dependencies():
    clear_screen()
    print(get_logo())
    print(f"\n{AZUL_BRILLANTE}[+] Verificando dependencias base...{RESET}")
    
    missing = []
    if shutil.which("fzf") is None:
        missing.append("fzf")
    if shutil.which("VBoxManage") is None:
        missing.append("virtualbox")

    if missing:
        print(f"{AMARILLO_BRILLANTE}[!] Faltan paquetes base: {missing}{RESET}")
        choice = fzf_menu(["Sí, instalar automáticamente", "No, salir"], prompt="¿Deseas instalarlas ahora? ")
        if choice != "Sí, instalar automáticamente":
            sys.exit(0)

        distro = detect_distro()
        if distro == "arch":
            run_cmd("sudo pacman -Syu --needed --noconfirm virtualbox virtualbox-host-dkms fzf")
        else:
            run_cmd("sudo apt-get update && sudo apt-get install -y virtualbox fzf")

    # Ejecutar verificación y autorreparación del kernel sí o sí
    ensure_vbox_kernel()
    print(f"{VERDE_BRILLANTE}[✓] Entorno completamente listo.{RESET}\n")
    input("Presiona Enter para continuar al menú...")

def find_images():
    search_dirs = [
        os.path.expanduser("~/Downloads"),
        os.path.expanduser("~/Descargas"),
        os.path.expanduser("~/VMs"),
        os.path.expanduser("~/ISOs"),
        os.path.expanduser("~/isos")
    ]
    images = []
    for d in search_dirs:
        if os.path.exists(d):
            for root, _, files in os.walk(d):
                for file in files:
                    if file.lower().endswith((".iso", ".ova")):
                        images.append(os.path.join(root, file))
    return images

def create_vm():
    clear_screen()
    print(get_logo())
    print(f"\n{AMARILLO_BRILLANTE}--- Importar / Crear Máquina Virtual ---{RESET}\n")
    
    images = find_images()
    if not images:
        print(f"{ROJO_BRILLANTE}[!] No se encontraron archivos .iso o .ova en las rutas habituales.{RESET}")
        input("Presiona Enter...")
        return

    selected_image = fzf_menu(images, prompt="Selecciona ISO u OVA: ")
    if not selected_image:
        return

    if selected_image.endswith(".ova"):
        print(f"\n{AZUL_BRILLANTE}[+] Importando archivo OVA en VirtualBox...{RESET}")
        
        res_before = subprocess.run("VBoxManage list vms", shell=True, capture_output=True, text=True)
        success = run_cmd(f"VBoxManage import '{selected_image}'")
        res_after = subprocess.run("VBoxManage list vms", shell=True, capture_output=True, text=True)
        
        if success:
            old_vms = set(res_before.stdout.splitlines())
            new_vms = set(res_after.stdout.splitlines())
            diff = new_vms - old_vms
            
            if diff:
                vm_line = list(diff)[0]
                vm_name = vm_line.split('"')[1]
                
                # Asegurar que existe una interfaz host-only (vboxnet0) para auditoría
                print(f"{AZUL_BRILLANTE}[+] Configurando red Host-Only para auditoría en '{vm_name}'...{RESET}")
                subprocess.run("VBoxManage hostonlyif create", shell=True, capture_output=True)
                
                # Asignar adaptador 1 a Host-Only para que sea accesible directamente desde tu Kali/Arch
                run_cmd(f"VBoxManage modifyvm '{vm_name}' --nic1 hostonly --hostonlyadapter1 'vboxnet0'")
                
            print(f"\n{VERDE_BRILLANTE}[✓] Máquina OVA importada y lista para auditar en red local virtual.{RESET}")
        else:
            print(f"\n{ROJO_BRILLANTE}[!] Error al importar el archivo OVA.{RESET}")
    else:
        vm_name = input("--> Nombre para la nueva VM: ").strip()
        if not vm_name:
            vm_name = "CTF_Machine"
        
        print(f"\n{AZUL_BRILLANTE}[+] Creando VM limpia y montando ISO...{RESET}")
        run_cmd(f"VBoxManage createvm --name '{vm_name}' --ostype 'Linux_64' --register")
        run_cmd(f"VBoxManage modifyvm '{vm_name}' --memory 2048 --cpus 2 --vram 128")
        run_cmd(f"VBoxManagecd storagectl '{vm_name}' --name 'IDE Controller' --add ide")
        run_cmd(f"VBoxManage storageattach '{vm_name}' --storagectl 'IDE Controller' --port 0 --device 0 --type dvddrive --medium '{selected_image}'")
        print(f"\n{VERDE_BRILLANTE}[✓] VM creada y lista.{RESET}")

    input("Presiona Enter para continuar...")

def manage_vms():
    while True:
        clear_screen()
        print(get_logo())
        print(f"\n{AMARILLO_BRILLANTE}--- Gestión de Máquinas Virtuales ---{RESET}\n")

        result = subprocess.run("VBoxManage list vms", shell=True, capture_output=True, text=True)
        raw_vms = result.stdout.splitlines()
        
        if not raw_vms:
            print(f"{ROJO_BRILLANTE}[!] No hay máquinas virtuales registradas en VirtualBox.{RESET}")
            input("Presiona Enter...")
            return

        vms = []
        for line in raw_vms:
            parts = line.split('"')
            if len(parts) >= 2:
                vms.append(parts[1])

        if not vms:
            print(f"{ROJO_BRILLANTE}[!] No se pudieron procesar las VMs.{RESET}")
            input("Presiona Enter...")
            return

        selected_vm = fzf_menu(vms, prompt="Selecciona VM: ")
        if not selected_vm:
            return

        action = fzf_menu([
            "1. Iniciar VM (Ventana Gráfica)", 
            "2. Iniciar VM en Segundo Plano (Headless)", 
            "3. Apagar VM Forzosamente (Power Off)", 
            "4. Eliminar VM por completo", 
            "5. Volver"
        ], prompt=f"Acción para [{selected_vm}]: ")

        if "1." in action:
            run_cmd(f"VBoxManage startvm '{selected_vm}'")
            print(f"{VERDE_BRILLANTE}[✓] VM iniciada en modo gráfico.{RESET}")
        elif "2." in action:
            run_cmd(f"VBoxManage startvm '{selected_vm}' --type headless")
            print(f"{VERDE_BRILLANTE}[✓] VM iniciada en segundo plano (headless).{RESET}")
        elif "3." in action:
            run_cmd(f"VBoxManage controlvm '{selected_vm}' poweroff")
            print(f"{AMARILLO_BRILLANTE}[!] VM apagada por la fuerza.{RESET}")
        elif "4." in action:
            confirm = fzf_menu(["Sí", "No"], prompt=f"¿Estás seguro de eliminar permanentemente '{selected_vm}'?")
            if confirm == "Sí":
                run_cmd(f"VBoxManage controlvm '{selected_vm}' poweroff")
                run_cmd(f"VBoxManage unregistervm '{selected_vm}' --delete")
                print(f"{ROJO_BRILLANTE}[✓] VM y discos eliminados por completo.{RESET}")
        
        input("Presiona Enter para continuar...")

def main():
    check_dependencies()
    while True:
        clear_screen()
        print(get_logo())
        options = [
            "1. Importar / Crear VM (ISO / OVA)",
            "2. Gestionar / Listar VMs",
            "3. Salir"
        ]
        choice = fzf_menu(options, prompt="Selecciona una opción: ")
        
        if "1." in choice:
            create_vm()
        elif "2." in choice:
            manage_vms()
        else:
            print(f"\n{AZUL_BRILLANTE}[i] ¡Hasta luego!{RESET}")
            break

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nSaliendo...")
        sys.exit(0)
