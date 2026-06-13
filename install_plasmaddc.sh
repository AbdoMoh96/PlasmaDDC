#!/usr/bin/env bash

set -u

APP_NAME="PlasmaDDC"

PROJECT_DIR="$HOME/Scripts/PlasmaDDC"
VENV_DIR="$PROJECT_DIR/.venv"
LOG_FILE="$PROJECT_DIR/install.log"
STATE_FILE="$PROJECT_DIR/.plasmaddc-install-state"

UDEV_RULE_FILE="/etc/udev/rules.d/60-plasmaddc-i2c.rules"
MODULE_LOAD_FILE="/etc/modules-load.d/plasmaddc-i2c-dev.conf"
DESKTOP_FILE="$HOME/.local/share/applications/plasmaddc.desktop"

DRY_RUN=0
STATE_TRACKING_ENABLED=1

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            echo "Uso: $0 [--dry-run]"
            echo
            echo "  --dry-run   Muestra lo que haría sin modificar el sistema."
            exit 0
            ;;
        *)
            echo "Argumento no reconocido: $arg"
            exit 1
            ;;
    esac
done

mkdir -p "$PROJECT_DIR"

touch "$LOG_FILE" 2>/dev/null || {
    echo "No se puede escribir el log en $LOG_FILE"
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

title() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo
    log "==== $1 ===="
}

info() {
    echo "INFO: $*"
    log "INFO: $*"
}

warn() {
    echo "AVISO: $*"
    log "AVISO: $*"
}

error() {
    echo "ERROR: $*"
    log "ERROR: $*"
}

ask_yes_no() {
    local question="$1"
    local answer

    while true; do
        echo
        read -r -p "$question [s/N]: " answer
        case "$answer" in
            s|S|si|SI|sí|SÍ|y|Y|yes|YES)
                return 0
                ;;
            ""|n|N|no|NO)
                return 1
                ;;
            *)
                echo "Responde s o n."
                ;;
        esac
    done
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

safe_state_key() {
    local raw="$1"
    raw="${raw^^}"
    raw="${raw//[^A-Z0-9]/_}"
    echo "$raw"
}

state_init() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se crea archivo de estado."
        return 0
    fi

    if [[ -f "$STATE_FILE" ]]; then
        warn "Ya existe un archivo de estado:"
        warn "$STATE_FILE"
        warn "Puede indicar una instalación anterior."

        if ask_yes_no "¿Quieres sobrescribir el estado de instalación?"; then
            cp "$STATE_FILE" "$STATE_FILE.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
            info "Copia de seguridad del estado anterior creada."
        else
            warn "No se sobrescribirá el estado."
            warn "El rollback inteligente quedará desactivado en esta ejecución."
            STATE_TRACKING_ENABLED=0
            return 0
        fi
    fi

    cat > "$STATE_FILE" <<EOF
# Estado de instalación de PlasmaDDC
# Generado automáticamente. No editar salvo que sepas lo que haces.
STATE_VERSION=1.2
INSTALL_DATE=$(date -Iseconds)
PROJECT_DIR=$PROJECT_DIR
USER_NAME=$USER
EOF

    info "Archivo de estado inicializado: $STATE_FILE"
}

state_set() {
    local key="$1"
    local value="$2"
    local tmp

    if [[ "$STATE_TRACKING_ENABLED" -ne 1 || "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi

    tmp="$(mktemp)"
    grep -v "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_get() {
    local key="$1"

    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi

    set +u
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    printf '%s' "${!key:-}"
    set -u
}

file_exists_bool() {
    if [[ -e "$1" ]]; then
        echo 1
    else
        echo 0
    fi
}

dir_exists_bool() {
    if [[ -d "$1" ]]; then
        echo 1
    else
        echo 0
    fi
}

group_exists_bool() {
    if getent group "$1" >/dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
}

user_in_group_bool() {
    local user="$1"
    local group="$2"

    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
        echo 1
    else
        echo 0
    fi
}

detect_package_manager() {
    if command_exists apt; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists pacman; then
        echo "pacman"
    elif command_exists zypper; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

is_package_installed() {
    local pm="$1"
    local package="$2"

    case "$pm" in
        apt)
            dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
            ;;
        dnf|zypper)
            rpm -q "$package" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Q "$package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

package_installed_bool() {
    local pm="$1"
    local package="$2"

    if is_package_installed "$pm" "$package"; then
        echo 1
    else
        echo 0
    fi
}

run_cmd() {
    local description="$1"
    shift

    echo
    echo "Operación propuesta:"
    echo "  $description"
    echo
    echo "Comando:"
    printf '  %q' "$@"
    echo

    log "OPERACIÓN PROPUESTA: $description"
    log "COMANDO: $*"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se ejecuta el comando."
        return 0
    fi

    if ask_yes_no "¿Quieres ejecutar esta operación?"; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        local status=${PIPESTATUS[0]}

        if [[ "$status" -ne 0 ]]; then
            warn "El comando terminó con código $status."
        fi

        return "$status"
    else
        warn "Operación omitida por el usuario."
        return 1
    fi
}

write_file_confirmed() {
    local file="$1"
    local description="$2"
    local content="$3"

    echo
    echo "Archivo propuesto:"
    echo "  $file"
    echo
    echo "$description"

    if [[ -f "$file" ]]; then
        warn "El archivo ya existe. No se sobrescribirá sin confirmación."
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se escribe $file."
        return 0
    fi

    if ask_yes_no "¿Quieres crear o actualizar este archivo?"; then
        mkdir -p "$(dirname "$file")"
        printf '%s\n' "$content" > "$file"
        info "Archivo escrito: $file"
        return 0
    else
        warn "No se ha modificado $file."
        return 1
    fi
}

install_packages_group() {
    local pm="$1"
    local description="$2"
    shift 2
    local packages=("$@")

    if [[ "${#packages[@]}" -eq 0 ]]; then
        return 0
    fi

    case "$pm" in
        apt)
            run_cmd "Actualizar la lista de paquetes antes de instalar" sudo apt update || true
            run_cmd "$description: ${packages[*]}" sudo apt install -y "${packages[@]}"
            ;;
        dnf)
            run_cmd "$description: ${packages[*]}" sudo dnf install -y "${packages[@]}"
            ;;
        pacman)
            run_cmd "$description: ${packages[*]}" sudo pacman -S --needed "${packages[@]}"
            ;;
        zypper)
            run_cmd "$description: ${packages[*]}" sudo zypper install -y "${packages[@]}"
            ;;
        *)
            error "No se ha detectado un gestor de paquetes soportado."
            warn "Instala manualmente: ${packages[*]}"
            return 1
            ;;
    esac
}

capture_initial_state() {
    local pm="$1"
    shift
    local packages=("$@")

    title "Estado previo para rollback inteligente"

    state_init

    if [[ "$STATE_TRACKING_ENABLED" -ne 1 ]]; then
        warn "Seguimiento de estado desactivado."
        return 0
    fi

    state_set "PROJECT_DIR_EXISTED_BEFORE" "$(dir_exists_bool "$PROJECT_DIR")"
    state_set "VENV_EXISTED_BEFORE" "$(dir_exists_bool "$VENV_DIR")"
    state_set "DESKTOP_FILE_EXISTED_BEFORE" "$(file_exists_bool "$DESKTOP_FILE")"
    state_set "UDEV_RULE_EXISTED_BEFORE" "$(file_exists_bool "$UDEV_RULE_FILE")"
    state_set "MODULE_LOAD_FILE_EXISTED_BEFORE" "$(file_exists_bool "$MODULE_LOAD_FILE")"
    state_set "I2C_GROUP_EXISTED_BEFORE" "$(group_exists_bool i2c)"
    state_set "USER_IN_I2C_BEFORE" "$(user_in_group_bool "$USER" i2c)"

    for package in "${packages[@]}"; do
        local key
        key="$(safe_state_key "$package")"
        state_set "PKG_${key}_BEFORE" "$(package_installed_bool "$pm" "$package")"
    done

    info "Estado previo guardado en $STATE_FILE"
}

capture_final_state() {
    local pm="$1"
    shift
    local packages=("$@")
    local installed_by_plasmaddc=()

    title "Estado final para rollback inteligente"

    if [[ "$STATE_TRACKING_ENABLED" -ne 1 || "$DRY_RUN" -eq 1 ]]; then
        info "No se actualiza estado final."
        return 0
    fi

    state_set "PROJECT_DIR_EXISTS_AFTER" "$(dir_exists_bool "$PROJECT_DIR")"
    state_set "VENV_EXISTS_AFTER" "$(dir_exists_bool "$VENV_DIR")"
    state_set "DESKTOP_FILE_EXISTS_AFTER" "$(file_exists_bool "$DESKTOP_FILE")"
    state_set "UDEV_RULE_EXISTS_AFTER" "$(file_exists_bool "$UDEV_RULE_FILE")"
    state_set "MODULE_LOAD_FILE_EXISTS_AFTER" "$(file_exists_bool "$MODULE_LOAD_FILE")"
    state_set "I2C_GROUP_EXISTS_AFTER" "$(group_exists_bool i2c)"
    state_set "USER_IN_I2C_AFTER" "$(user_in_group_bool "$USER" i2c)"

    if [[ "$(state_get VENV_EXISTED_BEFORE)" == "0" && "$(dir_exists_bool "$VENV_DIR")" == "1" ]]; then
        state_set "VENV_CREATED_BY_PLASMADDC" "1"
    else
        state_set "VENV_CREATED_BY_PLASMADDC" "0"
    fi

    if [[ "$(state_get DESKTOP_FILE_EXISTED_BEFORE)" == "0" && "$(file_exists_bool "$DESKTOP_FILE")" == "1" ]]; then
        state_set "DESKTOP_FILE_CREATED_BY_PLASMADDC" "1"
    else
        state_set "DESKTOP_FILE_CREATED_BY_PLASMADDC" "0"
    fi

    if [[ "$(state_get UDEV_RULE_EXISTED_BEFORE)" == "0" && "$(file_exists_bool "$UDEV_RULE_FILE")" == "1" ]]; then
        state_set "UDEV_RULE_CREATED_BY_PLASMADDC" "1"
    else
        state_set "UDEV_RULE_CREATED_BY_PLASMADDC" "0"
    fi

    if [[ "$(state_get MODULE_LOAD_FILE_EXISTED_BEFORE)" == "0" && "$(file_exists_bool "$MODULE_LOAD_FILE")" == "1" ]]; then
        state_set "MODULE_LOAD_FILE_CREATED_BY_PLASMADDC" "1"
    else
        state_set "MODULE_LOAD_FILE_CREATED_BY_PLASMADDC" "0"
    fi

    if [[ "$(state_get USER_IN_I2C_BEFORE)" == "0" && "$(user_in_group_bool "$USER" i2c)" == "1" ]]; then
        state_set "USER_ADDED_TO_I2C_BY_PLASMADDC" "1"
    else
        state_set "USER_ADDED_TO_I2C_BY_PLASMADDC" "0"
    fi

    for package in "${packages[@]}"; do
        local key before after
        key="$(safe_state_key "$package")"
        before="$(state_get "PKG_${key}_BEFORE")"
        after="$(package_installed_bool "$pm" "$package")"

        state_set "PKG_${key}_AFTER" "$after"

        if [[ "$before" == "0" && "$after" == "1" ]]; then
            installed_by_plasmaddc+=("$package")
        fi
    done

    state_set "PACKAGES_INSTALLED_BY_PLASMADDC" "${installed_by_plasmaddc[*]}"

    info "Estado final actualizado en $STATE_FILE"
}

check_i2c_devices() {
    if ls /dev/i2c-* >/dev/null 2>&1; then
        info "Se han encontrado dispositivos /dev/i2c-*:"

        ls -l /dev/i2c-* | tee -a "$LOG_FILE"
        return 0
    fi

    warn "No se han encontrado dispositivos /dev/i2c-*."
    warn "Puede que el módulo i2c-dev no esté cargado."

    run_cmd "Cargar el módulo i2c-dev para exponer /dev/i2c-*" sudo modprobe i2c-dev || true

    if ls /dev/i2c-* >/dev/null 2>&1; then
        info "Ahora aparecen dispositivos /dev/i2c-*:"

        ls -l /dev/i2c-* | tee -a "$LOG_FILE"

        echo
        echo "Se puede hacer persistente la carga del módulo i2c-dev creando:"
        echo "  $MODULE_LOAD_FILE"
        echo
        echo "Contenido propuesto:"
        echo "  i2c-dev"

        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Modo dry-run: no se crea configuración persistente para i2c-dev."
        elif ask_yes_no "¿Quieres hacer persistente la carga del módulo i2c-dev?"; then
            echo "i2c-dev" | sudo tee "$MODULE_LOAD_FILE" >/dev/null
            info "Creado $MODULE_LOAD_FILE"
        else
            info "No se crea carga persistente de i2c-dev."
        fi

        return 0
    fi

    warn "Siguen sin aparecer dispositivos /dev/i2c-* después de modprobe."
    return 1
}

try_ddcutil_detect() {
    if ! command_exists ddcutil; then
        error "ddcutil no está instalado o no está en PATH."
        return 1
    fi

    echo
    echo "Prueba sin sudo:"
    echo "  ddcutil detect"
    echo

    if ddcutil detect 2>&1 | tee -a "$LOG_FILE"; then
        info "ddcutil detect funciona sin sudo."
        return 0
    fi

    warn "ddcutil detect no ha funcionado sin sudo."
    warn "Ahora se ofrece probar con sudo."
    warn "Si con sudo funciona, casi seguro falta configurar permisos sobre /dev/i2c-*."

    if run_cmd "Probar detección de monitor con sudo" sudo ddcutil detect; then
        info "ddcutil detect funciona con sudo."
        warn "Conviene configurar permisos i2c para que funcione como usuario normal."
        return 2
    fi

    warn "ddcutil detect tampoco ha funcionado con sudo."
    warn "Posibles causas:"
    warn "- DDC/CI desactivado en el menú OSD del monitor."
    warn "- Cable, adaptador, dock o KVM problemático."
    warn "- Monitor incompatible o implementación DDC/CI limitada."
    warn "- Driver gráfico que no expone I2C."
    return 1
}

show_ddc_capabilities() {
    local use_sudo="$1"

    title "4B. Lectura de capacidades del monitor"

    if ! command_exists ddcutil; then
        warn "ddcutil no está disponible. Se omite la lectura de capacidades."
        return 1
    fi

    echo "Se puede leer qué controles VCP anuncia el monitor."
    echo "Esto ayuda a saber si soporta brillo, contraste, volumen, RGB, temperatura de color o cambio de entrada."

    if [[ "$use_sudo" == "yes" ]]; then
        run_cmd "Leer capacidades del monitor con sudo" sudo ddcutil capabilities || true
        run_cmd "Leer todos los VCP actuales con sudo" sudo ddcutil getvcp all || true
    else
        run_cmd "Leer capacidades del monitor sin sudo" ddcutil capabilities || true
        run_cmd "Leer todos los VCP actuales sin sudo" ddcutil getvcp all || true
    fi
}

configure_i2c_permissions() {
    title "5. Configuración segura de permisos I2C"

    echo "PlasmaDDC no debe ejecutarse como root."
    echo "La opción segura será usar el grupo i2c y una regla udev con permisos 0660."
    echo "No se usará chmod 666."

    if getent group i2c >/dev/null 2>&1; then
        info "El grupo i2c ya existe."
    else
        run_cmd "Crear el grupo i2c" sudo groupadd -f i2c || true
    fi

    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
        info "El usuario $USER ya pertenece al grupo i2c."
    else
        run_cmd "Añadir el usuario $USER al grupo i2c" sudo usermod -aG i2c "$USER" || true
        warn "Tendrás que cerrar sesión y volver a entrar para activar este cambio."
    fi

    local rule_content='KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"'

    echo
    echo "Regla udev propuesta:"
    echo "  $UDEV_RULE_FILE"
    echo
    echo "Contenido:"
    echo "  $rule_content"

    if [[ -f "$UDEV_RULE_FILE" ]]; then
        warn "La regla ya existe. Contenido actual:"
        sudo cat "$UDEV_RULE_FILE" | tee -a "$LOG_FILE" || true
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se crea ni modifica la regla udev."
    elif ask_yes_no "¿Quieres crear o actualizar la regla udev de PlasmaDDC?"; then
        echo "$rule_content" | sudo tee "$UDEV_RULE_FILE" >/dev/null
        info "Regla udev escrita en $UDEV_RULE_FILE"
    else
        warn "No se ha creado/modificado la regla udev."
    fi

    run_cmd "Recargar reglas udev" sudo udevadm control --reload-rules || true
    run_cmd "Aplicar reglas udev a los dispositivos actuales" sudo udevadm trigger || true
}

create_project_files() {
    title "6. Crear archivos base del proyecto"

    mkdir -p "$PROJECT_DIR/assets"

    write_file_confirmed "$PROJECT_DIR/requirements.txt" \
        "Dependencias Python de PlasmaDDC." \
        $'monitorcontrol\nPySide6'

    write_file_confirmed "$PROJECT_DIR/app.py" \
        "Aplicación temporal mínima para comprobar que PySide6 y el lanzador funcionan." \
        $'from PySide6.QtCore import Qt\nfrom PySide6.QtWidgets import QApplication, QLabel, QMainWindow, QVBoxLayout, QWidget\nimport sys\n\n\nclass MainWindow(QMainWindow):\n    def __init__(self):\n        super().__init__()\n        self.setWindowTitle("PlasmaDDC")\n        root = QWidget()\n        layout = QVBoxLayout(root)\n        label = QLabel(\n            "PlasmaDDC\\n\\n"\n            "Fase 1 completada.\\n"\n            "La interfaz real se programará en la siguiente fase."\n        )\n        label.setAlignment(Qt.AlignCenter)\n        layout.addWidget(label)\n        self.setCentralWidget(root)\n        self.resize(520, 260)\n\n\ndef main():\n    app = QApplication(sys.argv)\n    window = MainWindow()\n    window.show()\n    sys.exit(app.exec())\n\n\nif __name__ == "__main__":\n    main()'

    write_file_confirmed "$PROJECT_DIR/run_plasmaddc.sh" \
        "Lanzador interno: activa el entorno virtual y ejecuta la aplicación." \
        "#!/usr/bin/env bash
cd \"$PROJECT_DIR\" || exit 1

if [[ ! -x \"$VENV_DIR/bin/python\" ]]; then
    echo \"No existe el entorno virtual de PlasmaDDC: $VENV_DIR\"
    exit 1
fi

source \"$VENV_DIR/bin/activate\"
exec python \"$PROJECT_DIR/app.py\""

    if [[ -f "$PROJECT_DIR/run_plasmaddc.sh" ]]; then
        chmod +x "$PROJECT_DIR/run_plasmaddc.sh"
    fi
}

create_python_environment() {
    title "7. Crear entorno virtual Python e instalar dependencias"

    if [[ -d "$VENV_DIR" ]]; then
        info "El entorno virtual ya existe: $VENV_DIR"
    else
        run_cmd "Crear entorno virtual Python en $VENV_DIR" python3 -m venv "$VENV_DIR" || true
    fi

    if [[ -x "$VENV_DIR/bin/pip" ]]; then
        run_cmd "Instalar dependencias Python desde requirements.txt" "$VENV_DIR/bin/pip" install -r "$PROJECT_DIR/requirements.txt" || true
    else
        warn "No existe pip dentro del entorno virtual. No se pueden instalar dependencias Python."
    fi
}

test_monitorcontrol() {
    title "8. Prueba básica de monitorcontrol"

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        warn "No existe el Python del entorno virtual. Se omite la prueba."
        return 1
    fi

    echo "Se probará que Python pueda importar monitorcontrol y detectar monitores."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se ejecuta la prueba Python."
        return 0
    fi

    "$VENV_DIR/bin/python" - <<'PY' 2>&1 | tee -a "$LOG_FILE"
try:
    from monitorcontrol import get_monitors

    monitors = get_monitors()
    print(f"Monitores detectados por monitorcontrol: {len(monitors)}")

    for i, monitor in enumerate(monitors):
        print(f"Monitor {i}: {monitor}")
        try:
            with monitor:
                print("  Brillo:", monitor.get_luminance())
        except Exception as exc:
            print("  No se pudo leer brillo:", exc)

except Exception as exc:
    print("Error importando o usando monitorcontrol:", exc)
PY
}

create_desktop_launcher() {
    title "9. Crear lanzador en el menú de aplicaciones"

    local desktop_content
    desktop_content="[Desktop Entry]
Type=Application
Name=PlasmaDDC
GenericName=Monitor DDC/CI Control
Comment=Control de monitor mediante DDC/CI
Exec=$PROJECT_DIR/run_plasmaddc.sh
Icon=preferences-desktop-display
Terminal=false
Categories=Settings;HardwareSettings;Qt;
StartupNotify=true"

    write_file_confirmed "$DESKTOP_FILE" \
        "Lanzador estándar .desktop para que PlasmaDDC aparezca en el menú de KDE Plasma y otros escritorios compatibles." \
        "$desktop_content"

    if [[ -f "$DESKTOP_FILE" ]]; then
        chmod +x "$DESKTOP_FILE" || true
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se actualizan cachés de escritorio."
        return 0
    fi

    if command_exists update-desktop-database; then
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
        info "Ejecutado update-desktop-database."
    fi

    if command_exists kbuildsycoca6; then
        kbuildsycoca6 >/dev/null 2>&1 || true
        info "Ejecutado kbuildsycoca6."
    elif command_exists kbuildsycoca5; then
        kbuildsycoca5 >/dev/null 2>&1 || true
        info "Ejecutado kbuildsycoca5."
    fi
}

show_summary() {
    title "10. Resumen final"

    echo "Directorio del proyecto:"
    echo "  $PROJECT_DIR"
    echo
    echo "Log de instalación:"
    echo "  $LOG_FILE"
    echo
    echo "Archivo de estado:"
    echo "  $STATE_FILE"
    echo
    echo "Regla udev:"
    echo "  $UDEV_RULE_FILE"
    echo
    echo "Archivo persistente i2c-dev:"
    echo "  $MODULE_LOAD_FILE"
    echo
    echo "Lanzador de menú:"
    echo "  $DESKTOP_FILE"
    echo
    echo "Comandos de comprobación recomendados:"
    echo "  groups"
    echo "  ls -l /dev/i2c-*"
    echo "  ddcutil detect"
    echo "  ddcutil capabilities"
    echo "  $PROJECT_DIR/run_plasmaddc.sh"
    echo

    if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
        warn "IMPORTANTE: si se añadió tu usuario al grupo i2c, cierra sesión y vuelve a entrar."
    fi

    if [[ -f "$STATE_FILE" ]]; then
        echo
        echo "Resumen del estado guardado:"
        grep -E '^(STATE_VERSION|INSTALL_DATE|PROJECT_DIR|PACKAGES_INSTALLED_BY_PLASMADDC|USER_ADDED_TO_I2C_BY_PLASMADDC|UDEV_RULE_CREATED_BY_PLASMADDC|DESKTOP_FILE_CREATED_BY_PLASMADDC|VENV_CREATED_BY_PLASMADDC)=' "$STATE_FILE" 2>/dev/null || true
    fi

    info "Fase 1.2 finalizada."
}

main() {
    title "Instalador seguro de $APP_NAME - Fase 1.2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Modo dry-run activado. Se mostrará lo que se haría, pero no se cambiará el sistema."
    fi

    info "Directorio del proyecto: $PROJECT_DIR"
    info "Log: $LOG_FILE"

    title "1. Detección del sistema"

    local pm
    pm="$(detect_package_manager)"
    info "Gestor de paquetes detectado: $pm"

    if [[ -f /etc/os-release ]]; then
        info "Información de distribución:"
        grep -E '^(NAME|VERSION|ID|VERSION_CODENAME)=' /etc/os-release | tee -a "$LOG_FILE" || true
    fi

    title "2. Comprobación de paquetes necesarios"

    local mandatory_packages=()
    local optional_packages=()

    case "$pm" in
        apt)
            mandatory_packages=(ddcutil i2c-tools python3 python3-pip python3-venv)
            optional_packages=(ddcui)
            ;;
        dnf)
            mandatory_packages=(ddcutil i2c-tools python3 python3-pip)
            optional_packages=(ddcui)
            ;;
        pacman)
            mandatory_packages=(ddcutil i2c-tools python python-pip)
            optional_packages=()
            warn "En Arch/Manjaro ddcui puede no estar en repositorios oficiales; se omite en esta fase."
            ;;
        zypper)
            mandatory_packages=(ddcutil i2c-tools python3 python3-pip)
            optional_packages=(ddcui)
            ;;
        *)
            warn "No se puede instalar automáticamente porque no se detectó apt, dnf, pacman ni zypper."
            warn "Instala manualmente ddcutil, i2c-tools, python3, pip y venv."
            ;;
    esac

    capture_initial_state "$pm" "${mandatory_packages[@]}" "${optional_packages[@]}"

    if [[ "$pm" != "unknown" ]]; then
        echo "Paquetes obligatorios propuestos:"
        echo "  ${mandatory_packages[*]}"
        install_packages_group "$pm" "Instalar paquetes obligatorios" "${mandatory_packages[@]}" || true

        if [[ "${#optional_packages[@]}" -gt 0 ]]; then
            echo
            echo "Paquetes opcionales propuestos:"
            echo "  ${optional_packages[*]}"
            echo
            echo "ddcui no es necesario para PlasmaDDC, pero sirve para probar DDC/CI con una interfaz gráfica existente."

            if ask_yes_no "¿Quieres intentar instalar también los paquetes opcionales?"; then
                install_packages_group "$pm" "Instalar paquetes opcionales" "${optional_packages[@]}" || true
            else
                warn "Paquetes opcionales omitidos."
            fi
        fi
    fi

    title "3. Comprobación de dispositivos I2C"

    check_i2c_devices || true

    title "4. Prueba de detección de monitor con ddcutil"

    local detect_result=0
    try_ddcutil_detect
    detect_result=$?

    if [[ "$detect_result" -eq 0 ]]; then
        show_ddc_capabilities "no"
    elif [[ "$detect_result" -eq 2 ]]; then
        show_ddc_capabilities "yes"
    elif [[ "$detect_result" -eq 1 ]]; then
        echo
        echo "No se ha confirmado que el monitor responda a DDC/CI."
        echo "Puedes parar ahora y revisar el OSD del monitor, cable, adaptadores o drivers."

        if ! ask_yes_no "¿Quieres continuar igualmente con la preparación de permisos y Python?"; then
            warn "Instalación detenida por el usuario."
            capture_final_state "$pm" "${mandatory_packages[@]}" "${optional_packages[@]}"
            show_summary
            exit 1
        fi
    fi

    configure_i2c_permissions
    create_project_files
    create_python_environment
    test_monitorcontrol || true
    create_desktop_launcher
    capture_final_state "$pm" "${mandatory_packages[@]}" "${optional_packages[@]}"
    show_summary
}

main "$@"