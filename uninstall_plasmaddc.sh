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
            echo "Usage: $0 [--dry-run]"
            echo
            echo "  --dry-run   Shows what would be done without deleting or changing anything."
            exit 0
            ;;
        *)
            echo "Unrecognized argument: $arg"
            exit 1
            ;;
    esac
done

mkdir -p "$STATE_DIR"
touch "$LOG_FILE" 2>/dev/null || {
    echo "Cannot write the log to $LOG_FILE"
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
    echo "WARNING: $*"
    log "WARNING: $*"
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
        read -r -p "$question [y/N]: " answer
        case "$answer" in
            y|Y|yes|YES)
                return 0
                ;;
            ""|n|N|no|NO)
                return 1
                ;;
            *)
                echo "Answer y or n."
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
    echo "Proposed operation:"
    echo "  $description"
    echo
    echo "Command:"
    printf '  %q' "$@"
    echo

    log "PROPOSED OPERATION: $description"
    log "COMANDO: $*"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: the command is not executed."
        return 0
    fi

    if ask_yes_no "Do you want to run this operation?"; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        local status=${PIPESTATUS[0]}
        if [[ "$status" -ne 0 ]]; then
            warn "The command ended with code $status."
        fi
        return "$status"
    else
        warn "Operation skipped by user."
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
        info "Does not exist: $file"
        return 0
    fi

    echo
    echo "$description"
    echo "Path:"
    echo "  $file"

    if [[ -f "$file" ]]; then
        echo
        echo "First lines:"
        sed -n '1,20p' "$file" 2>/dev/null || true
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: not removing $file."
        return 0
    fi

    if ask_yes_no "Do you want to remove it?"; then
        rm -f -- "$file"
        info "Removed: $file"
        return 0
    else
        warn "Not removed: $file"
        return 1
    fi
}

remove_user_dir() {
    local dir="$1"
    local description="$2"

    if [[ ! -d "$dir" ]]; then
        info "The directory does not exist: $dir"
        return 0
    fi

    echo
    echo "$description"
    echo "Path:"
    echo "  $dir"
    echo
    echo "Approximate size:"
    du -sh "$dir" 2>/dev/null || true

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: not removing $dir."
        return 0
    fi

    if ask_yes_no "Do you want to remove this directory and all of its contents?"; then
        rm -rf -- "$dir"
        info "Directory removed: $dir"
        return 0
    else
        warn "Not removed: $dir"
        return 1
    fi
}

remove_system_file_state_aware() {
    local file="$1"
    local created_key="$2"
    local existed_before_key="$3"
    local description="$4"

    if [[ ! -e "$file" ]]; then
        info "Does not exist: $file"
        return 0
    fi

    local created existed_before
    created="$(state_get "$created_key")"
    existed_before="$(state_get "$existed_before_key")"

    echo
    echo "$description"
    echo "Path:"
    echo "  $file"

    echo
    echo "Current content:"
    sudo sed -n '1,40p' "$file" 2>/dev/null || true

    if [[ "$created" == "1" ]]; then
        echo
        echo "The state file says this file was created by PlasmaDDC."
        run_cmd "Remove system file $file" sudo rm -f "$file"
        local status=$?
        if [[ "$status" -eq 0 ]]; then
            SYSTEM_CHANGED=1
        fi
        return "$status"
    fi

    if [[ "$existed_before" == "1" ]]; then
        warn "The state file says this file ALREADY EXISTED before PlasmaDDC."
        warn "For safety, removing it automatically is not recommended."
    else
        warn "There is no certainty that this file was created by PlasmaDDC."
    fi

    if ask_yes_no "Do you want to remove it anyway?"; then
        run_cmd "Remove system file $file" sudo rm -f "$file"
        local status=$?
        if [[ "$status" -eq 0 ]]; then
            SYSTEM_CHANGED=1
        fi
        return "$status"
    else
        info "Kept: $file"
        return 0
    fi
}

refresh_desktop_cache() {
    if [[ "$DESKTOP_CHANGED" -ne 1 ]]; then
        return 0
    fi

    title "Update application menu cache"

    if command_exists update-desktop-database; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Dry-run mode: update-desktop-database is not run."
        else
            update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
            info "Ran update-desktop-database."
        fi
    fi

    if command_exists kbuildsycoca6; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Dry-run mode: kbuildsycoca6 is not run."
        else
            kbuildsycoca6 >/dev/null 2>&1 || true
            info "Ran kbuildsycoca6."
        fi
    elif command_exists kbuildsycoca5; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Dry-run mode: kbuildsycoca5 is not run."
        else
            kbuildsycoca5 >/dev/null 2>&1 || true
            info "Ran kbuildsycoca5."
        fi
    fi
}

refresh_udev_if_needed() {
    if [[ "$SYSTEM_CHANGED" -ne 1 ]]; then
        return 0
    fi

    title "Reload device rules"

    run_cmd "Reload udev rules" sudo udevadm control --reload-rules || true
    run_cmd "Apply udev rules to current devices" sudo udevadm trigger || true
}

remove_from_i2c_group_state_aware() {
    title "i2c group"

    if ! getent group i2c >/dev/null 2>&1; then
        info "The i2c group does not exist."
        return 0
    fi

    if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
        info "The user $USER does not belong to the i2c group."
        return 0
    fi

    local added_by_plasmaddc
    added_by_plasmaddc="$(state_get USER_ADDED_TO_I2C_BY_PLASMADDC)"

    if [[ "$added_by_plasmaddc" == "1" ]]; then
        echo "The state file says PlasmaDDC added your user to the i2c group."
        echo "Removing this membership may make ddcutil stop working without sudo."
        if ask_yes_no "Do you want to remove $USER from the i2c group?"; then
            run_cmd "Remove $USER from the i2c group" sudo gpasswd -d "$USER" i2c || true
            warn "Log out and log back in for the change to take effect."
        else
            info "The user remains in the i2c group."
        fi
        return 0
    fi

    warn "Your user belongs to the i2c group, but the state does not confirm that PlasmaDDC added it."
    warn "For safety, keeping it is recommended."

    if ask_yes_no "Do you want to remove it anyway?"; then
        run_cmd "Remove $USER from the i2c group" sudo gpasswd -d "$USER" i2c || true
        warn "Log out and log back in for the change to take effect."
    else
        info "The user remains in the i2c group."
    fi
}

remove_packages_optional() {
    title "Advanced option: packages installed by PlasmaDDC"

    local packages
    packages="$(state_get PACKAGES_INSTALLED_BY_PLASMADDC)"

    if [[ -z "$packages" ]]; then
        info "The state file does not list packages installed by PlasmaDDC."
        return 0
    fi

    echo "The state file says PlasmaDDC may have installed these packages:"
    echo
    echo "  $packages"
    echo
    echo "Removing them automatically is not recommended because they may be useful for other things."
    echo "For example: ddcutil, i2c-tools, or python3 may be useful outside PlasmaDDC."

    if ! ask_yes_no "Do you want to try removing these packages from the system?"; then
        info "System packages are kept."
        return 0
    fi

    local pm
    pm="$(detect_package_manager)"

    case "$pm" in
        apt)
            run_cmd "Remove packages with apt" sudo apt remove -y $packages || true
            ;;
        dnf)
            run_cmd "Remove packages with dnf" sudo dnf remove -y $packages || true
            ;;
        pacman)
            run_cmd "Remove packages with pacman" sudo pacman -Rns $packages || true
            ;;
        zypper)
            run_cmd "Remove packages with zypper" sudo zypper remove -y $packages || true
            ;;
        *)
            warn "No supported package manager was detected. Packages are not removed."
            ;;
    esac
}

remove_project_files_individually() {
    title "Remove base project files"

    remove_user_file "$PROJECT_DIR/app.py" \
        "Temporary or main PlasmaDDC application." || true

    remove_user_file "$PROJECT_DIR/run_plasmaddc.sh" \
        "Internal PlasmaDDC launcher script." || true

    remove_user_file "$PROJECT_DIR/requirements.txt" \
        "Python dependency file." || true

    remove_user_file "$PROJECT_DIR/install.log" \
        "Installer log." || true

    remove_user_dir "$PROJECT_DIR/assets" \
        "PlasmaDDC assets directory." || true
}

remove_entire_project_optional() {
    title "Optional complete deletion"

    if [[ ! -d "$PROJECT_DIR" ]]; then
        info "The project folder does not exist: $PROJECT_DIR"
        return 0
    fi

    if ! is_safe_project_dir; then
        error "Path not considered safe for automatic deletion: $PROJECT_DIR"
        return 1
    fi

    echo "Can be deleted completely:"
    echo "  $PROJECT_DIR"
    echo
    echo "This will also delete:"
    echo "  - install_plasmaddc.sh"
    echo "  - uninstall_plasmaddc.sh"
    echo "  - .plasmaddc-install-state"
    echo "  - any file you created inside"

    remove_user_dir "$PROJECT_DIR" \
        "Complete PlasmaDDC project folder." || true
}

show_summary() {
    title "Final summary"

    echo "Uninstaller log:"
    echo "  $LOG_FILE"
    echo
    echo "State file usado:"
    echo "  $STATE_FILE"
    echo
    echo "Recommended checks:"
    echo "  ls -l ~/.local/share/applications/plasmaddc.desktop"
    echo "  ls -l /etc/udev/rules.d/60-plasmaddc-i2c.rules"
    echo "  ls -l /etc/modules-load.d/plasmaddc-i2c-dev.conf"
    echo "  groups"
    echo "  ls -l /dev/i2c-*"
    echo

    info "Uninstaller finished."
}

main() {
    title "Safe uninstaller for $APP_NAME - Phase 1.2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Dry-run mode enabled. Nothing will be deleted or modified."
    fi

    echo "This uninstaller uses the state file if it exists:"
    echo "  $STATE_FILE"
    echo

    if [[ ! -f "$STATE_FILE" ]]; then
        warn "The state file does not exist."
        warn "This can happen if you installed PlasmaDDC with a version older than Phase 1.2."
        warn "Conservative cleanup with prompts will still be used."
    else
        info "State file encontrado."
        echo
        echo "State summary:"
        grep -E '^(STATE_VERSION|INSTALL_DATE|PROJECT_DIR|PACKAGES_INSTALLED_BY_PLASMADDC|USER_ADDED_TO_I2C_BY_PLASMADDC|UDEV_RULE_CREATED_BY_PLASMADDC|DESKTOP_FILE_CREATED_BY_PLASMADDC|VENV_CREATED_BY_PLASMADDC)=' "$STATE_FILE" 2>/dev/null || true
    fi

    title "1. Menu launcher"

    if [[ -e "$DESKTOP_FILE" ]]; then
        local_created="$(state_get DESKTOP_FILE_CREATED_BY_PLASMADDC)"

        if [[ "$local_created" == "1" ]]; then
            info "The state says the launcher was created by PlasmaDDC."
        else
            warn "The state does not confirm that the launcher was created by PlasmaDDC."
        fi

        remove_user_file "$DESKTOP_FILE" \
            "PlasmaDDC launcher in the application menu." && DESKTOP_CHANGED=1
    else
        info "The launcher does not exist: $DESKTOP_FILE"
    fi

    title "2. Python virtual environment"

    local_venv_created="$(state_get VENV_CREATED_BY_PLASMADDC)"

    if [[ "$local_venv_created" == "1" ]]; then
        info "The state says .venv was created by PlasmaDDC."
    elif [[ -d "$VENV_DIR" ]]; then
        warn " .venv exists, but the state does not confirm that PlasmaDDC created it."
    fi

    remove_user_dir "$VENV_DIR" \
        "PlasmaDDC Python virtual environment." || true

    title "3. System configuration"

    remove_system_file_state_aware "$UDEV_RULE_FILE" \
        "UDEV_RULE_CREATED_BY_PLASMADDC" \
        "UDEV_RULE_EXISTED_BEFORE" \
        "PlasmaDDC udev rule for /dev/i2c-* permissions." || true

    remove_system_file_state_aware "$MODULE_LOAD_FILE" \
        "MODULE_LOAD_FILE_CREATED_BY_PLASMADDC" \
        "MODULE_LOAD_FILE_EXISTED_BEFORE" \
        "Optional file to load i2c-dev automatically at startup." || true

    refresh_udev_if_needed

    title "4. Project files"

    if ask_yes_no "Do you want to remove base files inside the project?"; then
        remove_project_files_individually
    else
        info "Project base files are kept."
    fi

    title "5. User and i2c group"

    echo "Only touch this if you want to revert DDC/CI permissions."
    if ask_yes_no "Do you want to review user membership in the i2c group?"; then
        remove_from_i2c_group_state_aware
    else
        info "i2c group modification is skipped."
    fi

    title "6. System packages"

    echo "This section is advanced."
    echo "By default, it is better NOT to remove packages such as ddcutil, i2c-tools, or python3."
    if ask_yes_no "Do you want to review packages that PlasmaDDC may have installed?"; then
        remove_packages_optional
    else
        info "System packages are kept."
    fi

    title "7. Complete folder deletion"

    if ask_yes_no "Do you want to completely delete the folder $PROJECT_DIR?"; then
        remove_entire_project_optional
    else
        info "The project folder is kept."
    fi

    refresh_desktop_cache
    show_summary
}

main "$@"