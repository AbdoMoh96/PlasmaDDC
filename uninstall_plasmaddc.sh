#!/usr/bin/env bash

set -u

APP_NAME="PlasmaDDC"

PROJECT_DIR="$HOME/Scripts/PlasmaDDC"
VENV_DIR="$PROJECT_DIR/.venv"
STATE_FILE="$PROJECT_DIR/.plasmaddc-install-state"

DESKTOP_FILE="$HOME/.local/share/applications/plasmaddc.desktop"

UDEV_RULE_FILE="/etc/udev/rules.d/60-plasmaddc-i2c.rules"
MODULE_LOAD_FILE="/etc/modules-load.d/plasmaddc-i2c-dev.conf"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/plasmaddc"
LOG_FILE="$STATE_DIR/uninstall.log"

DRY_RUN=0
SYSTEM_CHANGED=0
DESKTOP_CHANGED=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            echo "Uso: $0 [--dry-run]"
            echo
            echo "  --dry-run   Muestra lo que haría sin borrar ni modificar nada."
            exit 0
            ;;
        *)
            echo "Argumento no reconocido: $arg"
            exit 1
            ;;
    esac
done

mkdir -p "$STATE_DIR"
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

is_safe_project_dir() {
    [[ "$PROJECT_DIR" == "$HOME/Scripts/PlasmaDDC" ]]
}

remove_user_file() {
    local file="$1"
    local description="$2"

    if [[ ! -e "$file" ]]; then
        info "No existe: $file"
        return 0
    fi

    echo
    echo "$description"
    echo "Ruta:"
    echo "  $file"

    if [[ -f "$file" ]]; then
        echo
        echo "Primeras líneas:"
        sed -n '1,20p' "$file" 2>/dev/null || true
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se elimina $file."
        return 0
    fi

    if ask_yes_no "¿Quieres eliminarlo?"; then
        rm -f -- "$file"
        info "Eliminado: $file"
        return 0
    else
        warn "No se ha eliminado: $file"
        return 1
    fi
}

remove_user_dir() {
    local dir="$1"
    local description="$2"

    if [[ ! -d "$dir" ]]; then
        info "No existe el directorio: $dir"
        return 0
    fi

    echo
    echo "$description"
    echo "Ruta:"
    echo "  $dir"
    echo
    echo "Tamaño aproximado:"
    du -sh "$dir" 2>/dev/null || true

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Modo dry-run: no se elimina $dir."
        return 0
    fi

    if ask_yes_no "¿Quieres eliminar este directorio y todo su contenido?"; then
        rm -rf -- "$dir"
        info "Directorio eliminado: $dir"
        return 0
    else
        warn "No se ha eliminado: $dir"
        return 1
    fi
}

remove_system_file_state_aware() {
    local file="$1"
    local created_key="$2"
    local existed_before_key="$3"
    local description="$4"

    if [[ ! -e "$file" ]]; then
        info "No existe: $file"
        return 0
    fi

    local created existed_before
    created="$(state_get "$created_key")"
    existed_before="$(state_get "$existed_before_key")"

    echo
    echo "$description"
    echo "Ruta:"
    echo "  $file"

    echo
    echo "Contenido actual:"
    sudo sed -n '1,40p' "$file" 2>/dev/null || true

    if [[ "$created" == "1" ]]; then
        echo
        echo "El archivo de estado indica que este archivo fue creado por PlasmaDDC."
        run_cmd "Eliminar archivo de sistema $file" sudo rm -f "$file"
        local status=$?
        if [[ "$status" -eq 0 ]]; then
            SYSTEM_CHANGED=1
        fi
        return "$status"
    fi

    if [[ "$existed_before" == "1" ]]; then
        warn "El archivo de estado indica que este archivo YA EXISTÍA antes de PlasmaDDC."
        warn "Por seguridad, no se recomienda eliminarlo automáticamente."
    else
        warn "No hay certeza de que este archivo fuera creado por PlasmaDDC."
    fi

    if ask_yes_no "¿Quieres eliminarlo igualmente?"; then
        run_cmd "Eliminar archivo de sistema $file" sudo rm -f "$file"
        local status=$?
        if [[ "$status" -eq 0 ]]; then
            SYSTEM_CHANGED=1
        fi
        return "$status"
    else
        info "Se conserva: $file"
        return 0
    fi
}

refresh_desktop_cache() {
    if [[ "$DESKTOP_CHANGED" -ne 1 ]]; then
        return 0
    fi

    title "Actualizar caché del menú de aplicaciones"

    if command_exists update-desktop-database; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Modo dry-run: no se ejecuta update-desktop-database."
        else
            update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
            info "Ejecutado update-desktop-database."
        fi
    fi

    if command_exists kbuildsycoca6; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Modo dry-run: no se ejecuta kbuildsycoca6."
        else
            kbuildsycoca6 >/dev/null 2>&1 || true
            info "Ejecutado kbuildsycoca6."
        fi
    elif command_exists kbuildsycoca5; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Modo dry-run: no se ejecuta kbuildsycoca5."
        else
            kbuildsycoca5 >/dev/null 2>&1 || true
            info "Ejecutado kbuildsycoca5."
        fi
    fi
}

refresh_udev_if_needed() {
    if [[ "$SYSTEM_CHANGED" -ne 1 ]]; then
        return 0
    fi

    title "Recargar reglas de dispositivos"

    run_cmd "Recargar reglas udev" sudo udevadm control --reload-rules || true
    run_cmd "Aplicar reglas udev a los dispositivos actuales" sudo udevadm trigger || true
}

remove_from_i2c_group_state_aware() {
    title "Grupo i2c"

    if ! getent group i2c >/dev/null 2>&1; then
        info "El grupo i2c no existe."
        return 0
    fi

    if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
        info "El usuario $USER no pertenece al grupo i2c."
        return 0
    fi

    local added_by_plasmaddc
    added_by_plasmaddc="$(state_get USER_ADDED_TO_I2C_BY_PLASMADDC)"

    if [[ "$added_by_plasmaddc" == "1" ]]; then
        echo "El archivo de estado indica que PlasmaDDC añadió tu usuario al grupo i2c."
        echo "Quitar esta pertenencia puede hacer que ddcutil deje de funcionar sin sudo."
        if ask_yes_no "¿Quieres quitar $USER del grupo i2c?"; then
            run_cmd "Quitar $USER del grupo i2c" sudo gpasswd -d "$USER" i2c || true
            warn "Cierra sesión y vuelve a entrar para que el cambio tenga efecto."
        else
            info "Se mantiene el usuario en el grupo i2c."
        fi
        return 0
    fi

    warn "Tu usuario pertenece al grupo i2c, pero el estado no confirma que lo añadiera PlasmaDDC."
    warn "Por seguridad, se recomienda mantenerlo."

    if ask_yes_no "¿Quieres quitarlo igualmente?"; then
        run_cmd "Quitar $USER del grupo i2c" sudo gpasswd -d "$USER" i2c || true
        warn "Cierra sesión y vuelve a entrar para que el cambio tenga efecto."
    else
        info "Se mantiene el usuario en el grupo i2c."
    fi
}

remove_packages_optional() {
    title "Opción avanzada: paquetes instalados por PlasmaDDC"

    local packages
    packages="$(state_get PACKAGES_INSTALLED_BY_PLASMADDC)"

    if [[ -z "$packages" ]]; then
        info "El archivo de estado no indica paquetes instalados por PlasmaDDC."
        return 0
    fi

    echo "El archivo de estado indica que PlasmaDDC pudo instalar estos paquetes:"
    echo
    echo "  $packages"
    echo
    echo "No se recomienda eliminarlos automáticamente, porque pueden servir para otras cosas."
    echo "Por ejemplo: ddcutil, i2c-tools o python3 pueden ser útiles fuera de PlasmaDDC."

    if ! ask_yes_no "¿Quieres intentar eliminar estos paquetes del sistema?"; then
        info "Se conservan los paquetes del sistema."
        return 0
    fi

    local pm
    pm="$(detect_package_manager)"

    case "$pm" in
        apt)
            run_cmd "Eliminar paquetes con apt" sudo apt remove -y $packages || true
            ;;
        dnf)
            run_cmd "Eliminar paquetes con dnf" sudo dnf remove -y $packages || true
            ;;
        pacman)
            run_cmd "Eliminar paquetes con pacman" sudo pacman -Rns $packages || true
            ;;
        zypper)
            run_cmd "Eliminar paquetes con zypper" sudo zypper remove -y $packages || true
            ;;
        *)
            warn "No se detectó gestor de paquetes soportado. No se eliminan paquetes."
            ;;
    esac
}

remove_project_files_individually() {
    title "Eliminar archivos base del proyecto"

    remove_user_file "$PROJECT_DIR/app.py" \
        "Aplicación temporal o principal de PlasmaDDC." || true

    remove_user_file "$PROJECT_DIR/run_plasmaddc.sh" \
        "Script lanzador interno de PlasmaDDC." || true

    remove_user_file "$PROJECT_DIR/requirements.txt" \
        "Archivo de dependencias Python." || true

    remove_user_file "$PROJECT_DIR/install.log" \
        "Log del instalador." || true

    remove_user_dir "$PROJECT_DIR/assets" \
        "Directorio assets de PlasmaDDC." || true
}

remove_entire_project_optional() {
    title "Borrado completo opcional"

    if [[ ! -d "$PROJECT_DIR" ]]; then
        info "La carpeta del proyecto no existe: $PROJECT_DIR"
        return 0
    fi

    if ! is_safe_project_dir; then
        error "Ruta no considerada segura para borrado automático: $PROJECT_DIR"
        return 1
    fi

    echo "Se puede eliminar completamente:"
    echo "  $PROJECT_DIR"
    echo
    echo "Esto borrará también:"
    echo "  - install_plasmaddc.sh"
    echo "  - uninstall_plasmaddc.sh"
    echo "  - .plasmaddc-install-state"
    echo "  - cualquier archivo que hayas creado dentro"

    remove_user_dir "$PROJECT_DIR" \
        "Carpeta completa del proyecto PlasmaDDC." || true
}

show_summary() {
    title "Resumen final"

    echo "Log del desinstalador:"
    echo "  $LOG_FILE"
    echo
    echo "Archivo de estado usado:"
    echo "  $STATE_FILE"
    echo
    echo "Comprobaciones recomendadas:"
    echo "  ls -l ~/.local/share/applications/plasmaddc.desktop"
    echo "  ls -l /etc/udev/rules.d/60-plasmaddc-i2c.rules"
    echo "  ls -l /etc/modules-load.d/plasmaddc-i2c-dev.conf"
    echo "  groups"
    echo "  ls -l /dev/i2c-*"
    echo

    info "Desinstalador finalizado."
}

main() {
    title "Desinstalador seguro de $APP_NAME - Fase 1.2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Modo dry-run activado. No se borrará ni modificará nada."
    fi

    echo "Este desinstalador usa el archivo de estado si existe:"
    echo "  $STATE_FILE"
    echo

    if [[ ! -f "$STATE_FILE" ]]; then
        warn "No existe archivo de estado."
        warn "Esto puede pasar si instalaste PlasmaDDC con una versión anterior a la Fase 1.2."
        warn "Se seguirá usando una limpieza conservadora con preguntas."
    else
        info "Archivo de estado encontrado."
        echo
        echo "Resumen del estado:"
        grep -E '^(STATE_VERSION|INSTALL_DATE|PROJECT_DIR|PACKAGES_INSTALLED_BY_PLASMADDC|USER_ADDED_TO_I2C_BY_PLASMADDC|UDEV_RULE_CREATED_BY_PLASMADDC|DESKTOP_FILE_CREATED_BY_PLASMADDC|VENV_CREATED_BY_PLASMADDC)=' "$STATE_FILE" 2>/dev/null || true
    fi

    title "1. Lanzador del menú"

    if [[ -e "$DESKTOP_FILE" ]]; then
        local_created="$(state_get DESKTOP_FILE_CREATED_BY_PLASMADDC)"

        if [[ "$local_created" == "1" ]]; then
            info "El estado indica que el lanzador fue creado por PlasmaDDC."
        else
            warn "El estado no confirma que el lanzador fuera creado por PlasmaDDC."
        fi

        remove_user_file "$DESKTOP_FILE" \
            "Lanzador de PlasmaDDC en el menú de aplicaciones." && DESKTOP_CHANGED=1
    else
        info "No existe el lanzador: $DESKTOP_FILE"
    fi

    title "2. Entorno virtual Python"

    local_venv_created="$(state_get VENV_CREATED_BY_PLASMADDC)"

    if [[ "$local_venv_created" == "1" ]]; then
        info "El estado indica que .venv fue creado por PlasmaDDC."
    elif [[ -d "$VENV_DIR" ]]; then
        warn "Existe .venv, pero el estado no confirma que lo creara PlasmaDDC."
    fi

    remove_user_dir "$VENV_DIR" \
        "Entorno virtual Python de PlasmaDDC." || true

    title "3. Configuración de sistema"

    remove_system_file_state_aware "$UDEV_RULE_FILE" \
        "UDEV_RULE_CREATED_BY_PLASMADDC" \
        "UDEV_RULE_EXISTED_BEFORE" \
        "Regla udev de PlasmaDDC para permisos sobre /dev/i2c-*." || true

    remove_system_file_state_aware "$MODULE_LOAD_FILE" \
        "MODULE_LOAD_FILE_CREATED_BY_PLASMADDC" \
        "MODULE_LOAD_FILE_EXISTED_BEFORE" \
        "Archivo opcional para cargar i2c-dev automáticamente al inicio." || true

    refresh_udev_if_needed

    title "4. Archivos del proyecto"

    if ask_yes_no "¿Quieres eliminar archivos base dentro del proyecto?"; then
        remove_project_files_individually
    else
        info "Se conservan los archivos base del proyecto."
    fi

    title "5. Usuario y grupo i2c"

    echo "Solo se recomienda tocar esto si quieres revertir permisos DDC/CI."
    if ask_yes_no "¿Quieres revisar la pertenencia del usuario al grupo i2c?"; then
        remove_from_i2c_group_state_aware
    else
        info "Se omite la modificación del grupo i2c."
    fi

    title "6. Paquetes del sistema"

    echo "Esta sección es avanzada."
    echo "Por defecto es mejor NO eliminar paquetes como ddcutil, i2c-tools o python3."
    if ask_yes_no "¿Quieres revisar paquetes que PlasmaDDC pudo instalar?"; then
        remove_packages_optional
    else
        info "Se conservan los paquetes del sistema."
    fi

    title "7. Borrado completo de carpeta"

    if ask_yes_no "¿Quieres borrar completamente la carpeta $PROJECT_DIR?"; then
        remove_entire_project_optional
    else
        info "Se conserva la carpeta del proyecto."
    fi

    refresh_desktop_cache
    show_summary
}

main "$@"