<div align="center">

# ⚡ QEMU4ME - Gestor Ultraligero de VMs para Pentesting

[![Version](https://img.shields.io/badge/version-3.2-blue)](https://github.com/DanSanMar/qemu4me)
![License](https://img.shields.io/badge/license-GPLv3-blue)
[![Platform](https://img.shields.io/badge/platform-Linux-orange)](https://www.linux.org/)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

*Parte de la suite ALL4ME*

**Gestor de máquinas virtuales QEMU nativo, minimalista y potente para entornos de pentesting.**

</div>

---

## 📖 Descripción

**QEMU4ME** es un gestor de máquinas virtuales ultraligero escrito en Bash puro que utiliza QEMU nativo (sin capas de abstracción pesadas). Diseñado específicamente para pentesters y auditores de seguridad, permite desplegar, gestionar y clonar VMs de forma rápida y eficiente desde la terminal.

---

## ✨ Características Principales

- 🚀 **Nativo y ligero** — Usa QEMU directamente, sin *overhead* innecesario.
- 🎨 **Interfaz TUI moderna** — Menús interactivos con `fzf` y previsualizaciones en vivo.
- 🔒 **Hardening integrado** — Modo Sandbox / Read-Only (`-snapshot`) para análisis seguro.
- 🌐 **Red Bridge aislada** — Integración automática con `virbr0` de libvirt / virt-manager.
- 📸 **Snapshots QCOW2** — Crear, listar, restaurar y eliminar snapshots del disco.
- 🧬 **Linked Clones** — Clonación instantánea con discos enlazados (*copy-on-write*).
- 📡 **Captura PCAP nativa** — Tráfico de red capturado directamente por QEMU.
- 🎛️ **Control QMP** — Pausar, reanudar, reiniciar y volcar memoria RAM para análisis forense.
- 📦 **Import/Export Bundles** — Empaqueta VMs completas en archivos `.tar.gz`.
- 🔍 **Auto-detección de ISO/OVA** — Escanea directorios comunes automáticamente.
- 🛠️ **Auto-instalación de dependencias** — Soporta Arch, Fedora y Debian / Ubuntu / Kali.
- 🎨 **Logo dinámico** — Interfaz visual interactiva al estilo *ALL4ME*.

---

## 🖥️ Requisitos

| Componente | Descripción |
| :--- | :--- |
| **SO** | Linux (Arch, Fedora, Debian/Ubuntu/Kali) |
| **QEMU** | `qemu-desktop` / `qemu-kvm` / `qemu-system-x86` |
| **fzf** | Selector fuzzy para los menús interactivos |
| **libvirt** | Para red bridge `virbr0` *(opcional pero recomendado)* |
| **socat / netcat** | Comunicación con sockets QMP |
| **xclip / wl-copy** | Soporte de portapapeles (X11 / Wayland) |

> [!TIP]
> El script instala automáticamente las dependencias faltantes según tu distribución.

---

## 🚀 Instalación

```bash
# Clonar el repositorio
git clone https://github.com/DanSanMar/qemu4me.git
cd qemu4me

# Dar permisos de ejecución
chmod +x qemu4me.sh

# Ejecutar (NO uses sudo)
./qemu4me.sh
```

> [!WARNING]
> **Importante:** No ejecutes el script con `sudo`. El script te solicitará permisos elevados únicamente cuando sea estrictamente necesario (configuración de red, módulos del kernel, etc.).

---

## 🎮 Uso

### Menú Principal

```text
--- ⚡ QEMU4ME | PENTEST VM MANAGER | v 3.2:12:34:56: ⚡---

  1. Crear VM Vulnerable
  2. Gestionar / Listar VMs
  3. Clonación Rápida (Linked)
  4. Importar Bundle (.tar.gz)
  5. Salir
```

### Crear una VM

1. **Nombre de la VM:** Sanitizado automáticamente.
2. **Selección de imagen:** Busca archivos `.iso` y `.ova` en directorios comunes:
   - `~/ISOs`, `~/isos`, `~/Downloads`, `~/Descargas`
   - `~/VMs`, `~/vms`, `~/VirtualBox VMs`
   - `~/Documents`, `~/Documentos`
3. **Recursos:** Configura RAM (1GB-8GB+), vCPUs (1-8+) y tamaño del disco QCOW2.
4. **Red:** Bridge automático a `virbr0` con MAC aleatoria.
5. **Modo de pantalla:** GUI (GTK/SDL), Headless, o VNC (`:1`).
6. **Captura PCAP:** Opcional; guarda el tráfico en `~/.config/qemu4me/captures/`.

### Gestión de VMs

Cada VM seleccionada cuenta con su propio submenú de control:

| Acción | Descripción |
| :--- | :--- |
| 🟢 **Arrancar (GUI)** | Ventana gráfica nativa |
| 🛡️ **Arrancar Sandbox** | Modo `-snapshot` (cambios descartados al apagar) |
| 📺 **Arrancar VNC** | Servidor VNC en puerto `5901` |
| 👻 **Arrancar Headless** | Ejecución sin GUI en segundo plano |
| ⚡ **Acceso Rápido** | Copia comandos SSH y ejecución al portapapeles |
| 🎛️ **Control QMP** | Pausa, reset, memory dump y consola interactiva |
| 📸 **Snapshots** | Gestión completa de instantáneas QCOW2 |
| 💾 **Adjuntar Recursos** | Discos secundarios e ISOs adicionales |
| 📦 **Exportar Bundle** | Empaqueta VM + discos en `.tar.gz` |
| 💀 **Apagar Forzado** | Detención directa del proceso QEMU |
| 🗑️ **Eliminar VM** | Borrado completo de script y discos asociados |

---

## 📁 Estructura de Directorios

```text
~/.config/qemu4me/
├── disks/          # Discos QCOW2 de las VMs
├── vms/            # Scripts de arranque (.sh) por VM
├── qmp/            # Sockets QMP y monitor
├── pids/           # PIDs de VMs activas
└── captures/       # Capturas PCAP de tráfico
```

---

## 🧪 Ejemplos de Uso

### Análisis de Malware en Sandbox

```bash
# Crear VM -> Arrancar en modo Sandbox
# Todos los cambios en disco se descartan al apagar la VM
./qemu4me.sh
# -> Gestionar VMs -> [VM] -> Arrancar Sandbox / Read-Only
```

### Volcado de Memoria Forense (Memory Dump)

```bash
# Con la VM en ejecución:
# -> Control QMP -> Memory Dump
# Introduce la ruta de destino (ejemplo: /tmp/memdump.raw)
```

### Clonación Rápida para Laboratorio

```bash
# -> Clonación Rápida (Linked)
# Selecciona la VM base -> Asigna nombre al clon
# El clon comparte el disco base mediante copy-on-write
```

### Exportar VM Completa

```bash
# -> Gestionar VMs -> [VM] -> Exportar Bundle
# Genera el archivo comprimido en ~/mi_vm_bundle.tar.gz
```

---

## 🔧 Configuración Avanzada

### Red Bridge Personalizada

Por defecto se utiliza el adaptador `virbr0` (creado por `libvirt`/`virt-manager`). Para verificar su estado:

```bash
ip link show dev virbr0
virsh net-list --all
```

### Modificar Recursos Post-Creación

Puedes editar directamente el script de arranque generado para cada VM:

```bash
micro ~/.config/qemu4me/vms/mi_vm.sh
```

Ajusta los parámetros de QEMU según requieras (`-m`, `-smp`, `-drive`, etc.).

---

## 🛡️ Seguridad

- **`umask 077`** aplicado en los scripts de VM para restringir la lectura únicamente al propietario.
- **Permisos `700`** configurados en directorios sensibles (`qmp/`, `pids/`).
- **Aislamiento de red:** Las VMs se canalizan a través de la interfaz `virbr0`.
- **Reglas de Firewall:** Configuración con `iptables` para reenvío de tráfico seguro.
- **Sockets QMP protegidos:** Control mediante `flock` para evitar condiciones de carrera.

---

## 🤝 Contribuir

¡Las contribuciones son bienvenidas! Si deseas colaborar:

1. Haz un **Fork** del proyecto.
2. Crea una rama para tu función (`git checkout -b feature/nueva-funcionalidad`).
3. Realiza tus cambios y haz **Commit** (`git commit -m 'Añade nueva funcionalidad'`).
4. Sube los cambios a tu rama (`git push origin feature/nueva-funcionalidad`).
5. Abre un **Pull Request**.

---

## 👤 Autor

**DanSanMar**

<div align="center">

⚡ *Parte de la suite ALL4ME* ⚡

</div>