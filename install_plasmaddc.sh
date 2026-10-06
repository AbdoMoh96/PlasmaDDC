#!/usr/bin/env bash

set -u

APP_NAME="PlasmaDDC"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
            echo "Usage: $0 [--dry-run]"
            echo
            echo "  --dry-run   Shows what would be done without changing the system."
            exit 0
            ;;
        *)
            echo "Unrecognized argument: $arg"
            exit 1
            ;;
    esac
done

mkdir -p "$PROJECT_DIR"

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

safe_state_key() {
    local raw="$1"
    raw="${raw^^}"
    raw="${raw//[^A-Z0-9]/_}"
    echo "$raw"
}

state_init() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: no state file is created."
        return 0
    fi

    if [[ -f "$STATE_FILE" ]]; then
        warn "A state file already exists:"
        warn "$STATE_FILE"
        warn "It may indicate a previous installation."

        if ask_yes_no "Do you want to overwrite the installation state?"; then
            cp "$STATE_FILE" "$STATE_FILE.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
            info "Backup of the previous state created."
        else
            warn "The state will not be overwritten."
            warn "Smart rollback will be disabled for this run."
            STATE_TRACKING_ENABLED=0
            return 0
        fi
    fi

    cat > "$STATE_FILE" <<EOF
# PlasmaDDC installation state
# Generated automatically. Do not edit unless you know what you are doing.
STATE_VERSION=1.2
INSTALL_DATE=$(date -Iseconds)
PROJECT_DIR=$PROJECT_DIR
USER_NAME=$USER
EOF

    info "State file initialized: $STATE_FILE"
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

write_file_confirmed() {
    local file="$1"
    local description="$2"
    local content="$3"

    echo
    echo "Proposed file:"
    echo "  $file"
    echo
    echo "$description"

    if [[ -f "$file" ]]; then
        warn "The file already exists. It will not be overwritten without confirmation."
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: not writing $file."
        return 0
    fi

    if ask_yes_no "Do you want to create or update this file?"; then
        mkdir -p "$(dirname "$file")"
        printf '%s\n' "$content" > "$file"
        info "File written: $file"
        return 0
    else
        warn "Not modified $file."
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
            run_cmd "Update package list before installing" sudo apt update || true
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
            error "No supported package manager was detected."
            warn "Install manually: ${packages[*]}"
            return 1
            ;;
    esac
}

capture_initial_state() {
    local pm="$1"
    shift
    local packages=("$@")

    title "Previous state for smart rollback"

    state_init

    if [[ "$STATE_TRACKING_ENABLED" -ne 1 ]]; then
        warn "State tracking disabled."
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

    info "Previous state saved in $STATE_FILE"
}

capture_final_state() {
    local pm="$1"
    shift
    local packages=("$@")
    local installed_by_plasmaddc=()

    title "Final state for smart rollback"

    if [[ "$STATE_TRACKING_ENABLED" -ne 1 || "$DRY_RUN" -eq 1 ]]; then
        info "Final state is not updated."
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

    info "Final state updated in $STATE_FILE"
}

check_i2c_devices() {
    if ls /dev/i2c-* >/dev/null 2>&1; then
        info "Found /dev/i2c-* devices:"

        ls -l /dev/i2c-* | tee -a "$LOG_FILE"
        return 0
    fi

    warn "No /dev/i2c-* devices found."
    warn "The i2c-dev module may not be loaded."

    run_cmd "Load the i2c-dev module to expose /dev/i2c-*" sudo modprobe i2c-dev || true

    if ls /dev/i2c-* >/dev/null 2>&1; then
        info "/dev/i2c-* devices now appear:"

        ls -l /dev/i2c-* | tee -a "$LOG_FILE"

        echo
        echo "The i2c-dev module load can be made persistent by creating:"
        echo "  $MODULE_LOAD_FILE"
        echo
        echo "Proposed content:"
        echo "  i2c-dev"

        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "Dry-run mode: persistent i2c-dev configuration is not created."
        elif ask_yes_no "Do you want to make loading the i2c-dev module persistent?"; then
            echo "i2c-dev" | sudo tee "$MODULE_LOAD_FILE" >/dev/null
            info "Created $MODULE_LOAD_FILE"
        else
            info "Persistent i2c-dev loading is not created."
        fi

        return 0
    fi

    warn "/dev/i2c-* devices still do not appear after modprobe."
    return 1
}

try_ddcutil_detect() {
    if ! command_exists ddcutil; then
        error "ddcutil is not installed or is not in PATH."
        return 1
    fi

    echo
    echo "Test without sudo:"
    echo "  ddcutil detect"
    echo

    if ddcutil detect 2>&1 | tee -a "$LOG_FILE"; then
        info "ddcutil detect works without sudo."
        return 0
    fi

    warn "ddcutil detect did not work without sudo."
    warn "Testing with sudo is now offered."
    warn "If it works with sudo, /dev/i2c-* permissions almost certainly need configuration."

    if run_cmd "Test monitor detection with sudo" sudo ddcutil detect; then
        info "ddcutil detect works with sudo."
        warn "Configure i2c permissions so it works as a normal user."
        return 2
    fi

    warn "ddcutil detect did not work with sudo either."
    warn "Possible causes:"
    warn "- DDC/CI disabled in the monitor OSD menu."
    warn "- Problematic cable, adapter, dock, or KVM."
    warn "- Incompatible monitor or limited DDC/CI implementation."
    warn "- Graphics driver that does not expose I2C."
    return 1
}

show_ddc_capabilities() {
    local use_sudo="$1"

    title "4B. Monitor capability reading"

    if ! command_exists ddcutil; then
        warn "ddcutil is not available. Capability reading is skipped."
        return 1
    fi

    echo "You can read which VCP controls the monitor advertises."
    echo "This helps determine whether it supports brightness, contrast, volume, RGB, color temperature, or input switching."

    if [[ "$use_sudo" == "yes" ]]; then
        run_cmd "Read monitor capabilities with sudo" sudo ddcutil capabilities || true
        run_cmd "Read all current VCPs with sudo" sudo ddcutil getvcp all || true
    else
        run_cmd "Read monitor capabilities without sudo" ddcutil capabilities || true
        run_cmd "Read all current VCPs without sudo" ddcutil getvcp all || true
    fi
}

configure_i2c_permissions() {
    title "5. Safe I2C permissions configuration"

    echo "PlasmaDDC should not be run as root."
    echo "The safe option is to use the i2c group and a udev rule with 0660 permissions."
    echo "chmod 666 will not be used."

    if getent group i2c >/dev/null 2>&1; then
        info "The i2c group already exists."
    else
        run_cmd "Create the i2c group" sudo groupadd -f i2c || true
    fi

    if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
        info "The user $USER already belongs to the i2c group."
    else
        run_cmd "Add user $USER to the i2c group" sudo usermod -aG i2c "$USER" || true
        warn "You must log out and log back in to activate this change."
    fi

    local rule_content='KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"'

    echo
    echo "Proposed udev rule:"
    echo "  $UDEV_RULE_FILE"
    echo
    echo "Content:"
    echo "  $rule_content"

    if [[ -f "$UDEV_RULE_FILE" ]]; then
        warn "The rule already exists. Current content:"
        sudo cat "$UDEV_RULE_FILE" | tee -a "$LOG_FILE" || true
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: the udev rule is not created or modified."
    elif ask_yes_no "Do you want to create or update the PlasmaDDC udev rule?"; then
        echo "$rule_content" | sudo tee "$UDEV_RULE_FILE" >/dev/null
        info "Udev rule written to $UDEV_RULE_FILE"
    else
        warn "The udev rule was not created/modified."
    fi

    run_cmd "Reload udev rules" sudo udevadm control --reload-rules || true
    run_cmd "Apply udev rules to current devices" sudo udevadm trigger || true
}

create_project_files() {
    title "6. Install PlasmaDDC application files"

    mkdir -p "$PROJECT_DIR/assets" "$PROJECT_DIR/docs"

    if [[ ! -f "$SCRIPT_DIR/app.py" || ! -f "$SCRIPT_DIR/backend.py" ]]; then
        error "Real PlasmaDDC source files were not found in $SCRIPT_DIR."
        return 1
    fi

    echo "Installing the real PlasmaDDC interface from:"
    echo "  $SCRIPT_DIR"
    echo "to:"
    echo "  $PROJECT_DIR"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: application files are not copied."
        return 0
    fi

    install -m 0644 "$SCRIPT_DIR/app.py" "$PROJECT_DIR/app.py"
    install -m 0644 "$SCRIPT_DIR/backend.py" "$PROJECT_DIR/backend.py"
    install -m 0644 "$SCRIPT_DIR/plasmaddc_cli.py" "$PROJECT_DIR/plasmaddc_cli.py"
    install -m 0644 "$SCRIPT_DIR/requirements.txt" "$PROJECT_DIR/requirements.txt"

    for optional_file in README.md pyproject.toml LICENSE .gitignore; do
        if [[ -f "$SCRIPT_DIR/$optional_file" ]]; then
            install -m 0644 "$SCRIPT_DIR/$optional_file" "$PROJECT_DIR/$optional_file"
        fi
    done

    if [[ -d "$SCRIPT_DIR/docs" ]]; then
        cp -a "$SCRIPT_DIR/docs/." "$PROJECT_DIR/docs/"
    fi

    install -m 0755 "$SCRIPT_DIR/run_plasmaddc.sh" "$PROJECT_DIR/run_plasmaddc.sh"

    info "Installed the real PlasmaDDC GUI files."
}

create_python_environment() {
    title "7. Create Python virtual environment and install dependencies"

    if [[ -d "$VENV_DIR" ]]; then
        info "The virtual environment already exists: $VENV_DIR"
    else
        run_cmd "Create Python virtual environment in $VENV_DIR" python3 -m venv "$VENV_DIR" || true
    fi

    if [[ -x "$VENV_DIR/bin/pip" ]]; then
        run_cmd "Install Python dependencies from requirements.txt" "$VENV_DIR/bin/pip" install -r "$PROJECT_DIR/requirements.txt" || true
    else
        warn "pip does not exist inside the virtual environment. Python dependencies cannot be installed."
    fi
}

test_monitorcontrol() {
    title "8. Basic monitorcontrol test"

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        warn "The virtual-environment Python does not exist. The test is skipped."
        return 1
    fi

    echo "Python will be tested for importing monitorcontrol and detecting monitors."

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: the Python test is not run."
        return 0
    fi

    "$VENV_DIR/bin/python" - <<'PY' 2>&1 | tee -a "$LOG_FILE"
try:
    from monitorcontrol import get_monitors

    monitors = get_monitors()
    print(f"Monitors detected by monitorcontrol: {len(monitors)}")

    for i, monitor in enumerate(monitors):
        print(f"Monitor {i}: {monitor}")
        try:
            with monitor:
                print("  Brightness:", monitor.get_luminance())
        except Exception as exc:
            print("  Could not read brightness:", exc)

except Exception as exc:
    print("Error importing or using monitorcontrol:", exc)
PY
}

create_desktop_launcher() {
    title "9. Create launcher in the application menu"

    local desktop_content
    desktop_content="[Desktop Entry]
Type=Application
Name=PlasmaDDC
GenericName=Monitor DDC/CI Control
Comment=Monitor control through DDC/CI
Exec=$PROJECT_DIR/run_plasmaddc.sh
Icon=preferences-desktop-display
Terminal=false
Categories=Settings;HardwareSettings;Qt;
StartupNotify=true"

    write_file_confirmed "$DESKTOP_FILE" \
        "Standard .desktop launcher so PlasmaDDC appears in the KDE Plasma menu and other compatible desktops." \
        "$desktop_content"

    if [[ -f "$DESKTOP_FILE" ]]; then
        chmod +x "$DESKTOP_FILE" || true
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "Dry-run mode: desktop caches are not updated."
        return 0
    fi

    if command_exists update-desktop-database; then
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
        info "Ran update-desktop-database."
    fi

    if command_exists kbuildsycoca6; then
        kbuildsycoca6 >/dev/null 2>&1 || true
        info "Ran kbuildsycoca6."
    elif command_exists kbuildsycoca5; then
        kbuildsycoca5 >/dev/null 2>&1 || true
        info "Ran kbuildsycoca5."
    fi
}

show_summary() {
    title "10. Final summary"

    echo "Project directory:"
    echo "  $PROJECT_DIR"
    echo
    echo "Installation log:"
    echo "  $LOG_FILE"
    echo
    echo "State file:"
    echo "  $STATE_FILE"
    echo
    echo "Udev rule:"
    echo "  $UDEV_RULE_FILE"
    echo
    echo "Persistent i2c-dev file:"
    echo "  $MODULE_LOAD_FILE"
    echo
    echo "Menu launcher:"
    echo "  $DESKTOP_FILE"
    echo
    echo "Recommended check commands:"
    echo "  groups"
    echo "  ls -l /dev/i2c-*"
    echo "  ddcutil detect"
    echo "  ddcutil capabilities"
    echo "  $PROJECT_DIR/run_plasmaddc.sh"
    echo

    if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx i2c; then
        warn "IMPORTANT: if your user was added to the i2c group, log out and log back in."
    fi

    if [[ -f "$STATE_FILE" ]]; then
        echo
        echo "Saved state summary:"
        grep -E '^(STATE_VERSION|INSTALL_DATE|PROJECT_DIR|PACKAGES_INSTALLED_BY_PLASMADDC|USER_ADDED_TO_I2C_BY_PLASMADDC|UDEV_RULE_CREATED_BY_PLASMADDC|DESKTOP_FILE_CREATED_BY_PLASMADDC|VENV_CREATED_BY_PLASMADDC)=' "$STATE_FILE" 2>/dev/null || true
    fi

    info "Phase 1.2 completed."
}

main() {
    title "Safe installer for $APP_NAME - Phase 1.2"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Dry-run mode enabled. What would be done will be shown, but the system will not be changed."
    fi

    info "Project directory: $PROJECT_DIR"
    info "Log: $LOG_FILE"

    title "1. System detection"

    local pm
    pm="$(detect_package_manager)"
    info "Detected package manager: $pm"

    if [[ -f /etc/os-release ]]; then
        info "Distribution information:"
        grep -E '^(NAME|VERSION|ID|VERSION_CODENAME)=' /etc/os-release | tee -a "$LOG_FILE" || true
    fi

    title "2. Required package check"

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
            warn "On Arch/Manjaro, ddcui may not be in official repositories; it is skipped in this phase."
            ;;
        zypper)
            mandatory_packages=(ddcutil i2c-tools python3 python3-pip)
            optional_packages=(ddcui)
            ;;
        *)
            warn "Cannot install automatically because apt, dnf, pacman, or zypper was not detected."
            warn "Install manually ddcutil, i2c-tools, python3, pip y venv."
            ;;
    esac

    capture_initial_state "$pm" "${mandatory_packages[@]}" "${optional_packages[@]}"

    if [[ "$pm" != "unknown" ]]; then
        echo "Proposed mandatory packages:"
        echo "  ${mandatory_packages[*]}"
        install_packages_group "$pm" "Install mandatory packages" "${mandatory_packages[@]}" || true

        if [[ "${#optional_packages[@]}" -gt 0 ]]; then
            echo
            echo "Proposed optional packages:"
            echo "  ${optional_packages[*]}"
            echo
            echo "ddcui is not required for PlasmaDDC, but it is useful to test DDC/CI with an existing graphical interface."

            if ask_yes_no "Do you want to try installing optional packages too?"; then
                install_packages_group "$pm" "Install optional packages" "${optional_packages[@]}" || true
            else
                warn "Optional packages skipped."
            fi
        fi
    fi

    title "3. I2C device check"

    check_i2c_devices || true

    title "4. Monitor detection test with ddcutil"

    local detect_result=0
    try_ddcutil_detect
    detect_result=$?

    if [[ "$detect_result" -eq 0 ]]; then
        show_ddc_capabilities "no"
    elif [[ "$detect_result" -eq 2 ]]; then
        show_ddc_capabilities "yes"
    elif [[ "$detect_result" -eq 1 ]]; then
        echo
        echo "It has not been confirmed that the monitor responds to DDC/CI."
        echo "You can stop now and check the monitor OSD, cable, adapters, or drivers."

        if ! ask_yes_no "Do you want to continue with permissions and Python preparation anyway?"; then
            warn "Installation stopped by user."
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