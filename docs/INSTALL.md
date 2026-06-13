# Installation

This document explains how to prepare a Linux system and install PlasmaDDC.

PlasmaDDC controls external monitors through DDC/CI. It uses `ddcutil` as the main backend and Python/PySide6 for the graphical interface.

## 1. Physical requirements

Before installing anything, check:

- The monitor is external.
- The monitor supports DDC/CI.
- DDC/CI is enabled in the monitor OSD menu.
- The monitor is connected through HDMI, DisplayPort, DVI or VGA.
- The system exposes I2C devices as `/dev/i2c-*`.

Internal laptop panels usually do not use DDC/CI in the same way as external monitors.

## 2. Quick installation

From the project directory:

```bash
chmod +x install_plasmaddc.sh
./install_plasmaddc.sh
```

Do not run the installer with `sudo`.

The installer will ask for `sudo` only when it needs to install system packages or configure system permissions.

## 3. What the installer does

The installer is interactive and conservative.

It can:

- detect the Linux package manager
- install required system packages
- check `/dev/i2c-*`
- test `ddcutil detect`
- configure the `i2c` group
- create a udev rule for `/dev/i2c-*`
- create a Python virtual environment
- install Python dependencies
- create a desktop launcher
- create an installation state file for safer uninstall

It asks before making important changes.

## 4. Manual installation on Ubuntu / Kubuntu / Debian

Install system packages:

```bash
sudo apt update
sudo apt install ddcutil ddcui i2c-tools python3-pip python3-venv
```

`ddcui` is optional, but useful for testing DDC/CI with an existing graphical interface.

## 5. Configure I2C permissions

PlasmaDDC should not be run as root.

Create the `i2c` group if needed:

```bash
sudo groupadd -f i2c
```

Add your user to the group:

```bash
sudo usermod -aG i2c "$USER"
```

Create a udev rule:

```bash
echo 'KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"' | sudo tee /etc/udev/rules.d/60-plasmaddc-i2c.rules
```

Reload udev:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Log out and log back in.

Then verify:

```bash
groups
ls -l /dev/i2c-*
ddcutil detect
```

Your user should belong to the `i2c` group, and `/dev/i2c-*` should usually belong to `root:i2c`.

## 6. Create the Python environment manually

From the project directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 7. Run PlasmaDDC

Graphical interface:

```bash
./run_plasmaddc.sh
```

CLI:

```bash
source .venv/bin/activate
python plasmaddc_cli.py list
python plasmaddc_cli.py profile
```

## 8. Test DDC/CI manually

Useful commands:

```bash
ddcutil detect
ddcutil capabilities
ddcutil getvcp all
```

Common VCP tests:

```bash
ddcutil getvcp 10   # brightness
ddcutil getvcp 12   # contrast
ddcutil getvcp 14   # color preset
ddcutil getvcp 16   # red gain
ddcutil getvcp 18   # green gain
ddcutil getvcp 1A   # blue gain
ddcutil getvcp 60   # input source
ddcutil getvcp 62   # audio volume
```

## 9. Fedora, Arch and openSUSE

The installer has basic support for `dnf`, `pacman` and `zypper`, but the project is currently developed and tested mainly on Kubuntu/Ubuntu/Debian.

Approximate package names:

### Fedora

```bash
sudo dnf install ddcutil ddcui i2c-tools python3 python3-pip
```

### Arch / Manjaro

```bash
sudo pacman -S ddcutil i2c-tools python python-pip
```

`ddcui` may require AUR.

### openSUSE

```bash
sudo zypper install ddcutil i2c-tools python3 python3-pip
```

After installing packages, configure I2C permissions as described above.

## 10. Installation success criteria

The system is ready when these work without `sudo`:

```bash
ddcutil detect
ddcutil capabilities
ddcutil getvcp 10
```

And these work inside the virtual environment:

```bash
source .venv/bin/activate
python backend.py
python plasmaddc_cli.py profile
python app.py
```
