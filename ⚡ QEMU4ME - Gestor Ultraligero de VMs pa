⚡ QEMU4ME - Gestor Ultraligero de VMs para Pentesting
<div align="center">

https://img.shields.io/badge/version-3.2-blue
https://img.shields.io/badge/license-MIT-green
https://img.shields.io/badge/platform-Linux-orange
https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white

Parte de la suite ALL4ME

Gestor de máquinas virtuales QEMU nativo, minimalista y potente para entornos de pentesting.
</div>
📖 Descripción

QEMU4ME es un gestor de máquinas virtuales ultraligero escrito en Bash puro que utiliza QEMU nativo (sin capas de abstracción pesadas). Diseñado específicamente para pentesters y auditores de seguridad, permite desplegar, gestionar y clonar VMs de forma rápida y eficiente desde la terminal.
✨ Características Principales

    🚀 Nativo y ligero — Usa QEMU directamente, sin overhead innecesario

    🎨 Interfaz TUI moderna — Menús interactivos con fzf y previews en vivo

    🔒 Hardening integrado — Modo Sandbox/Read-Only (-snapshot) para análisis seguro

    🌐 Red Bridge aislada — Integración automática con virbr0 de libvirt/virt-manager

    📸 Snapshots QCOW2 — Crear, listar, restaurar y eliminar snapshots del disco

    🧬 Linked Clones — Clonación instantánea con discos enlazados (copy-on-write)

    📡 Captura PCAP nativa — Tráfico de red capturado directamente por QEMU

    🎛️ Control QMP — Pausar, reanudar, reiniciar y volcar memoria RAM para forense

    📦 Import/Export Bundles — Empaqueta VMs completas en .tar.gz

    🔍 Auto-detección de ISO/OVA — Escanea directorios comunes automáticamente

    🛠️ Auto-instalación de dependencias — Soporta Arch, Fedora y Debian/Ubuntu/Kali

    🎨 Logo dinámico con colores rotativos — Interfaz visual all4me

🖥️ Requisitos
Componente	Descripción
SO	Linux (Arch, Fedora, Debian/Ubuntu/Kali)
QEMU	qemu-desktop / qemu-kvm / qemu-system-x86
fzf	Selector fuzzy para los menús
libvirt	Para red bridge virbr0 (opcional pero recomendado)
socat / netcat	Comunicación con sockets QMP
xclip / wl-copy	Portapapeles (X11/Wayland)

    💡 El script instala automáticamente todas las dependencias faltantes según tu distribución.

🚀 Instalación
bash

# Clonar el repositorio
git clone https://github.com/DanSanMar/qemu4me.git
cd qemu4me

# Dar permisos de ejecución
chmod +x qemu4me.sh

# Ejecutar (NO uses sudo)
./qemu4me.sh

    ⚠️ Importante: No ejecutes el script con sudo. El script te solicitará permisos elevados únicamente cuando sea necesario (redes, módulos del kernel, etc.).

🎮 Uso
Menú Principal
text

--- ⚡ QEMU4ME | PENTEST VM MANAGER | v 3.2:12:34:56: ⚡---

  1. Crear VM Vulnerable
  2. Gestionar / Listar VMs
  3. Clonación Rápida (Linked)
  4. Importar Bundle (.tar.gz)
  5. Salir

Crear una VM

    Nombre de la VM (sanitizado automáticamente)

    Selección de imagen — Busca .iso y .ova en directorios comunes:

        ~/ISOs, ~/isos, ~/Downloads, ~/Descargas

        ~/VMs, ~/vms, ~/VirtualBox VMs

        ~/Documents, ~/Documentos

    Recursos — RAM (1GB-8GB+), vCPUs (1-8+), tamaño de disco QCOW2

    Red — Bridge automático a virbr0 con MAC aleatoria

    Modo de pantalla — GUI (GTK/SDL), Headless, o VNC :1

    Captura PCAP — Opcional, guarda tráfico en ~/.config/qemu4me/captures/

Gestión de VMs

Cada VM tiene su propio submenú con:
Acción	Descripción
🟢 Arrancar (GUI)	Ventana gráfica nativa
🛡️ Arrancar Sandbox	Modo -snapshot (cambios descartados al apagar)
📺 Arrancar VNC	Servidor VNC en puerto 5901
👻 Arrancar Headless	Sin GUI, en segundo plano
⚡ Acceso Rápido	Copia comandos SSH/ejecución al portapapeles
🎛️ Control QMP	Pausa, reset, memory dump, consola interactiva
📸 Snapshots	Gestión completa de instantáneas QCOW2
💾 Adjuntar Recursos	Discos secundarios e ISOs adicionales
📦 Exportar Bundle	Empaqueta VM + discos en .tar.gz
💀 Apagar Forzado	Kill del proceso QEMU
🗑️ Eliminar VM	Borrado completo (script + discos)
📁 Estructura de Directorios
text

~/.config/qemu4me/
├── disks/          # Discos QCOW2 de las VMs
├── vms/            # Scripts de arranque (.sh) por VM
├── qmp/            # Sockets QMP y monitor
├── pids/           # PIDs de VMs activas
└── captures/       # Capturas PCAP

🧪 Ejemplos de Uso
Análisis de Malware en Sandbox
bash

# Crear VM → Arrancar en modo Sandbox
# Todos los cambios se descartan al apagar
./qemu4me.sh
# → Gestionar VMs → [VM] → Arrancar Sandbox / Read-Only

Memory Dump Forense
bash

# Con la VM corriendo:
# → Control QMP → Memory Dump
# Introduce la ruta: /tmp/memdump.raw

Clonación Rápida para Laboratorio
bash

# → Clonación Rápida (Linked)
# Selecciona VM base → Nombre del clon
# El clon comparte el disco base (copy-on-write)

Exportar VM Completa
bash

# → Gestionar VMs → [VM] → Exportar Bundle
# Resultado: ~/mi_vm_bundle.tar.gz

🔧 Configuración Avanzada
Red Bridge Personalizada

Por defecto se usa virbr0 (creado por libvirt/virt-manager). Para verificar:
bash

ip link show dev virbr0
virsh net-list --all

Modificar Recursos Post-Creación

Edita directamente el script de la VM:
bash

micro ~/.config/qemu4me/vms/mi_vm.sh

Busca y modifica -m, -smp, -drive, etc.
🛡️ Seguridad

    umask 077 en scripts de VM — Solo el usuario propietario puede leerlos

    Permisos 700 en directorios sensibles (QMP, PID)

    Bridge aislado — Las VMs solo acceden a la red a través de virbr0

    Reglas de firewall — iptables configuradas para forwarding seguro

    Sockets QMP con lock — flock previene condiciones de carrera

🤝 Contribuir

Las contribuciones son bienvenidas. Por favor:

    Fork el proyecto

    Crea una rama (git checkout -b feature/nueva-funcionalidad)

    Commit tus cambios (git commit -m 'Añade nueva funcionalidad')

    Push a la rama (git push origin feature/nueva-funcionalidad)

    Abre un Pull Request

👤 Autor

DanSanMar

<div align="center">

⚡ Parte de la suite ALL4ME ⚡


</div>