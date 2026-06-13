# Uninstall

This document explains how to remove PlasmaDDC safely.

PlasmaDDC includes a conservative uninstaller. It asks before removing files or changing system configuration.

## 1. Run the uninstaller

From the project directory:

```bash
chmod +x uninstall_plasmaddc.sh
./uninstall_plasmaddc.sh
```

Do not run the uninstaller with `sudo`.

The script will ask for `sudo` only if it needs to remove system files such as udev rules.

## 2. Dry-run mode

To preview what the uninstaller would do without changing anything:

```bash
./uninstall_plasmaddc.sh --dry-run
```

This is the safest way to review the cleanup process before actually removing anything.

## 3. What the uninstaller can remove

The uninstaller may offer to remove:

- the desktop launcher
- the Python virtual environment `.venv`
- the PlasmaDDC udev rule
- the optional `i2c-dev` module-load file
- generated project files
- installation logs
- the whole project directory
- the user membership in the `i2c` group
- packages that the installer may have installed

It asks before doing any important operation.

## 4. What the uninstaller does not remove automatically

By default, it does not blindly remove system packages such as:

- `ddcutil`
- `ddcui`
- `i2c-tools`
- `python3`
- `python3-pip`
- `python3-venv`

These packages may be useful outside PlasmaDDC.

It also does not remove the `i2c` group itself by default.

## 5. Installation state file

The installer can create this file:

```text
.plasmaddc-install-state
```

This file records what existed before installation and what PlasmaDDC created.

The uninstaller uses it to make safer decisions.

For example:

- if PlasmaDDC created the udev rule, the uninstaller can offer to remove it
- if the udev rule existed before PlasmaDDC, the uninstaller warns before touching it
- if PlasmaDDC added your user to the `i2c` group, the uninstaller can offer to revert that
- if your user already belonged to `i2c`, the uninstaller avoids removing it automatically

If the state file does not exist, the uninstaller still works, but it uses a more conservative cleanup mode.

## 6. Files commonly removed

User files:

```text
~/.local/share/applications/plasmaddc.desktop
```

Project files:

```text
.venv/
install.log
.plasmaddc-install-state
```

System files, only with confirmation:

```text
/etc/udev/rules.d/60-plasmaddc-i2c.rules
/etc/modules-load.d/plasmaddc-i2c-dev.conf
```

## 7. Keeping I2C permissions

It is usually safe to keep your user in the `i2c` group.

Keeping this permission allows you to continue using:

```bash
ddcutil detect
ddcutil capabilities
ddcutil getvcp all
```

without `sudo`.

If you remove your user from the `i2c` group, you may need to log out and log back in before the change takes effect.

## 8. Manual cleanup

If you want to remove only the Python environment:

```bash
rm -rf .venv
```

If you want to remove the user desktop launcher:

```bash
rm -f ~/.local/share/applications/plasmaddc.desktop
```

If you want to remove the udev rule manually:

```bash
sudo rm -f /etc/udev/rules.d/60-plasmaddc-i2c.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

If you want to remove your user from the `i2c` group:

```bash
sudo gpasswd -d "$USER" i2c
```

Then log out and log back in.

## 9. Recommended uninstall path

For most users:

```bash
./uninstall_plasmaddc.sh
```

Choose:

- remove the desktop launcher
- remove `.venv`
- remove the PlasmaDDC udev rule only if you no longer need DDC/CI without sudo
- keep system packages unless you are sure you do not need them
- keep the `i2c` group unless you explicitly want to revert permissions
