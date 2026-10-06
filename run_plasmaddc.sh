#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python"
APP_FILE="$SCRIPT_DIR/app.py"

cd "$SCRIPT_DIR"

if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "The PlasmaDDC virtual environment does not exist:"
    echo "  $SCRIPT_DIR/.venv"
    echo
    echo "Run this first:"
    echo "  ./install_plasmaddc.sh"
    echo
    echo "Or create the environment manually:"
    echo "  python3 -m venv .venv"
    echo "  source .venv/bin/activate"
    echo "  pip install -r requirements.txt"
    exit 1
fi

if [[ ! -f "$APP_FILE" ]]; then
    echo "app.py was not found in:"
    echo "  $SCRIPT_DIR"
    exit 1
fi

exec "$VENV_PYTHON" "$APP_FILE"
