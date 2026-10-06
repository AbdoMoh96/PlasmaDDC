#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from typing import NoReturn

from backend import (
    COMMON_INPUT_SOURCES,
    COMMON_VCPS,
    PlasmaDDCBackend,
    PlasmaDDCError,
    VCPValue,
    color_preset_label,
    format_vcp_code,
    input_source_label,
    input_source_to_int,
    normalize_vcp_code,
)


APP_NAME = "PlasmaDDC CLI"


CONTROL_ALIASES = {
    "brightness": "brightness",
    "contrast": "contrast",
    "volume": "volume",
    "audio": "volume",
    "input": "input_source",
    "source": "input_source",
    "input-source": "input_source",
    "color": "color_preset",
    "preset": "color_preset",
    "color-preset": "color_preset",
    "temperature": "color_preset",
    "red": "red_gain",
    "r": "red_gain",
    "green": "green_gain",
    "g": "green_gain",
    "blue": "blue_gain",
    "b": "blue_gain",
    "rgb": "rgb",
}


def die(message: str, code: int = 1) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def human_monitor_to_index(value: int) -> int:
    if value < 1:
        raise argparse.ArgumentTypeError("Monitor must be 1, 2, 3...")
    return value - 1


def ask_confirmation(question: str) -> bool:
    while True:
        answer = input(f"{question} [y/N]: ").strip().lower()

        if answer in ("y", "yes"):
            return True

        if answer in ("", "n", "no"):
            return False

        print("Answer y or n.")


def normalize_control(name: str) -> str:
    key = name.strip().lower()

    if key not in CONTROL_ALIASES:
        valid = ", ".join(sorted(CONTROL_ALIASES))
        raise ValueError(f"Unknown control: {name}. Valid: {valid}")

    return CONTROL_ALIASES[key]


def print_vcp(value: VCPValue, prefix: str = "") -> None:
    name = value.name or "VCP"

    if value.current is not None and value.maximum is not None:
        print(
            f"{prefix}{value.code_hex} {name}: "
            f"{value.current}/{value.maximum}"
        )
        return

    if value.selector is not None:
        label = f" - {value.label}" if value.label else ""
        print(
            f"{prefix}{value.code_hex} {name}: "
            f"0x{value.selector:02X}{label}"
        )
        return

    if value.current is not None:
        print(f"{prefix}{value.code_hex} {name}: {value.current}")
        return

    if value.label:
        print(f"{prefix}{value.code_hex} {name}: {value.label}")
        return

    print(f"{prefix}{value.code_hex} {name}: no interpreted value")


def print_monitor_header(index: int, label: str) -> None:
    print()
    print(f"Monitor {index + 1}: {label}")
    print("-" * (len(label) + 11))


def get_backend() -> PlasmaDDCBackend:
    return PlasmaDDCBackend()


def cmd_list(args: argparse.Namespace) -> int:
    backend = get_backend()
    monitors = backend.refresh_monitors()

    if not monitors:
        print("No monitors detected.")
        return 1

    print(f"Detected monitors: {len(monitors)}")

    for monitor in monitors:
        print_monitor_header(monitor.index, monitor.label)
        print(f"CLI index:       {monitor.index + 1}")
        print(f"display_number:   {monitor.display_number}")
        print(f"bus_number:       {monitor.bus_number}")
        print(f"bus_path:         {monitor.bus_path}")
        print(f"drm_connector:    {monitor.drm_connector}")
        print(f"manufacturer_id:  {monitor.manufacturer_id}")
        print(f"model_name:       {monitor.model_name}")
        print(f"serial_number:    {monitor.serial_number}")

    return 0


def cmd_profile(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    profile = backend.build_monitor_profile(args.monitor)

    print_monitor_header(profile.monitor.index, profile.monitor.label)

    if profile.values:
        print("Common values:")
        for key in COMMON_VCPS:
            value = profile.values.get(key)
            if value is not None:
                print(f"  {key:14s}", end="")
                print_vcp(value, prefix=" ")
            elif key in profile.errors:
                print(f"  {key:14s} unavailable: {profile.errors[key]}")

    if profile.errors:
        print()
        print("Errores/unavailables:")
        for key, message in profile.errors.items():
            print(f"  {key}: {message}")

    return 0


def read_control(backend: PlasmaDDCBackend, monitor: int, control: str) -> list[VCPValue]:
    if control == "brightness":
        return [backend.get_brightness(monitor)]

    if control == "contrast":
        return [backend.get_contrast(monitor)]

    if control == "volume":
        return [backend.get_volume(monitor)]

    if control == "input_source":
        return [backend.get_input_source(monitor)]

    if control == "color_preset":
        return [backend.get_color_preset(monitor)]

    if control == "red_gain":
        return [backend.get_rgb_gain(monitor, "red")]

    if control == "green_gain":
        return [backend.get_rgb_gain(monitor, "green")]

    if control == "blue_gain":
        return [backend.get_rgb_gain(monitor, "blue")]

    if control == "rgb":
        return [
            backend.get_rgb_gain(monitor, "red"),
            backend.get_rgb_gain(monitor, "green"),
            backend.get_rgb_gain(monitor, "blue"),
        ]

    raise ValueError(f"Control unsupported: {control}")


def cmd_get(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    control = normalize_control(args.control)
    values = read_control(backend, args.monitor, control)

    for value in values:
        print_vcp(value)

        if value.code == COMMON_VCPS["input_source"] and value.selector is not None:
            print(f"Normalized label: {input_source_label(value.selector)}")

        if value.code == COMMON_VCPS["color_preset"] and value.selector is not None:
            print(f"Normalized label: {color_preset_label(value.selector)}")

    return 0


def cmd_set(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    control = normalize_control(args.control)
    value = args.value

    if control == "rgb":
        die("To change RGB, use red, green, or blue separately.")

    if control == "brightness":
        result = backend.set_brightness(args.monitor, int(value))
    elif control == "contrast":
        result = backend.set_contrast(args.monitor, int(value))
    elif control == "volume":
        result = backend.set_volume(args.monitor, int(value))
    elif control == "red_gain":
        result = backend.set_rgb_gain(args.monitor, "red", int(value))
    elif control == "green_gain":
        result = backend.set_rgb_gain(args.monitor, "green", int(value))
    elif control == "blue_gain":
        result = backend.set_rgb_gain(args.monitor, "blue", int(value))
    elif control == "color_preset":
        result = backend.set_color_preset(args.monitor, value)
    elif control == "input_source":
        raw_input = input_source_to_int(value)

        print("WARNING: you are about to change the monitor video input.")
        print(f"Requested target: {value} / 0x{raw_input:02X} / {input_source_label(raw_input)}")
        print("If you choose an input without signal, you may lose the picture until you switch it back from the monitor OSD.")

        if not args.yes and not ask_confirmation("Continue with the input switch?"):
            print("Operation cancelled.")
            return 1

        result = backend.set_input_source(args.monitor, raw_input)
    else:
        raise ValueError(f"Control unsupported for set: {control}")

    if result:
        print(result)
    else:
        print("Operation completed.")

    return 0


def cmd_capabilities(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    print(backend.get_capabilities_text(args.monitor))
    return 0


def cmd_getvcp_all(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    print(backend.get_all_vcps_text(args.monitor))
    return 0


def cmd_getvcp(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    value = backend.get_vcp(args.monitor, args.code)
    print_vcp(value)

    if args.raw:
        print()
        print("Raw output:")
        print(value.raw_output)

    return 0


def cmd_setvcp(args: argparse.Namespace) -> int:
    backend = get_backend()
    backend.refresh_monitors()

    code = normalize_vcp_code(args.code)
    code_text = format_vcp_code(code)

    print("WARNING: you are about to write a VCP code directly.")
    print(f"Code: {code_text}")
    print(f"Value:  {args.value}")
    print("This may change internal monitor settings.")

    if code == COMMON_VCPS["input_source"]:
        print("This VCP is Input Source. You may lose the picture if you choose an input without signal.")

    if not args.yes and not ask_confirmation("Continue with setvcp?"):
        print("Operation cancelled.")
        return 1

    result = backend.set_vcp(
        index=args.monitor,
        code=args.code,
        value=args.value,
        no_verify=args.no_verify,
        permit_unknown=args.permit_unknown,
    )

    if result:
        print(result)
    else:
        print("Operation completed.")

    return 0


def cmd_inputs(args: argparse.Namespace) -> int:
    print("Known common inputs:")
    print()

    seen: set[int] = set()

    for name, value in sorted(COMMON_INPUT_SOURCES.items(), key=lambda item: item[1]):
        if value in seen:
            continue
        seen.add(value)
        print(f"0x{value:02X}  {input_source_label(value)}")

    print()
    print("You can also use aliases such as HDMI1, HDMI2, DP1, DP2.")
    return 0


def cmd_presets(args: argparse.Namespace) -> int:
    print("Common color presets:")
    print()
    for value in sorted(range(1, 14)):
        print(f"0x{value:02X}  {color_preset_label(value)}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="plasmaddc_cli.py",
        description="Test CLI for PlasmaDDC.",
    )

    parser.add_argument(
        "-m",
        "--monitor",
        type=human_monitor_to_index,
        default=0,
        metavar="N",
        help="Monitor to use, starting at 1. Default: 1.",
    )

    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
    )

    p_list = subparsers.add_parser(
        "list",
        help="List detected monitors.",
    )
    p_list.set_defaults(func=cmd_list)

    p_profile = subparsers.add_parser(
        "profile",
        help="Show a summarized monitor profile.",
    )
    p_profile.set_defaults(func=cmd_profile)

    p_get = subparsers.add_parser(
        "get",
        help="Read a known control.",
    )
    p_get.add_argument(
        "control",
        help="brightness, contrast, volume, input, color, red, green, blue, rgb.",
    )
    p_get.set_defaults(func=cmd_get)

    p_set = subparsers.add_parser(
        "set",
        help="Change a known control.",
    )
    p_set.add_argument(
        "control",
        help="brightness, contrast, volume, input, color, red, green, blue.",
    )
    p_set.add_argument(
        "value",
        help="Value to write. Example: 70, HDMI1, 0x11, 0x05.",
    )
    p_set.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Do not ask for confirmation for delicate operations.",
    )
    p_set.set_defaults(func=cmd_set)

    p_caps = subparsers.add_parser(
        "capabilities",
        help="Show monitor ddcutil capabilities.",
    )
    p_caps.set_defaults(func=cmd_capabilities)

    p_all = subparsers.add_parser(
        "getvcp-all",
        help="Show monitor ddcutil getvcp all.",
    )
    p_all.set_defaults(func=cmd_getvcp_all)

    p_getvcp = subparsers.add_parser(
        "getvcp",
        help="Read a raw VCP.",
    )
    p_getvcp.add_argument(
        "code",
        help="Code VCP hexadecimal. Ejemplo: 10, 0x10, 1A.",
    )
    p_getvcp.add_argument(
        "--raw",
        action="store_true",
        help="Also show raw ddcutil output.",
    )
    p_getvcp.set_defaults(func=cmd_getvcp)

    p_setvcp = subparsers.add_parser(
        "setvcp",
        help="Write a raw VCP.",
    )
    p_setvcp.add_argument(
        "code",
        help="Code VCP hexadecimal. Ejemplo: 10, 0x10, 1A.",
    )
    p_setvcp.add_argument(
        "value",
        help="Value to write.",
    )
    p_setvcp.add_argument(
        "--no-verify",
        action="store_true",
        help="Use --noverify in ddcutil.",
    )
    p_setvcp.add_argument(
        "--permit-unknown",
        action="store_true",
        help="Use --permit-unknown-feature in ddcutil.",
    )
    p_setvcp.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Do not ask for confirmation.",
    )
    p_setvcp.set_defaults(func=cmd_setvcp)

    p_inputs = subparsers.add_parser(
        "inputs",
        help="Show common video input codes.",
    )
    p_inputs.set_defaults(func=cmd_inputs)

    p_presets = subparsers.add_parser(
        "presets",
        help="Show common color presets.",
    )
    p_presets.set_defaults(func=cmd_presets)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        print()
        print("Cancelled by user.")
        return 130
    except PlasmaDDCError as exc:
        die(str(exc))
    except ValueError as exc:
        die(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
