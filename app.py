#!/usr/bin/env python3
from __future__ import annotations

import sys
from dataclasses import dataclass
from functools import partial
from typing import Callable

from PySide6.QtCore import Qt
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QFrame,
    QFormLayout,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QSlider,
    QSpinBox,
    QSplitter,
    QStackedWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from backend import (
    COMMON_INPUT_SOURCES,
    COMMON_VCPS,
    PlasmaDDCBackend,
    PlasmaDDCError,
    VCPValue,
    color_preset_label,
    input_source_label,
    input_source_to_int,
)


APP_NAME = "PlasmaDDC"


@dataclass(frozen=True)
class PageInfo:
    title: str
    subtitle: str


def unique_input_sources() -> list[tuple[str, int]]:
    seen: set[int] = set()
    result: list[tuple[str, int]] = []

    for _, value in sorted(COMMON_INPUT_SOURCES.items(), key=lambda item: item[1]):
        if value in seen:
            continue
        seen.add(value)
        result.append((input_source_label(value), value))

    return result


def common_color_presets() -> list[tuple[str, int]]:
    return [(color_preset_label(value), value) for value in range(1, 14)]


class ValueControl(QWidget):
    def __init__(
        self,
        title: str,
        apply_callback: Callable[[int], None],
        read_callback: Callable[[], None] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)

        self.title = title
        self.apply_callback = apply_callback
        self.read_callback = read_callback

        self.name_label = QLabel(title)
        self.name_label.setMinimumWidth(130)

        self.slider = QSlider(Qt.Horizontal)
        self.slider.setRange(0, 100)
        self.slider.setSingleStep(1)
        self.slider.setPageStep(5)

        self.spin = QSpinBox()
        self.spin.setRange(0, 100)
        self.spin.setMinimumWidth(80)

        self.apply_button = QPushButton("Apply")
        self.read_button = QPushButton("Read")
        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)

        self.slider.valueChanged.connect(self.spin.setValue)
        self.spin.valueChanged.connect(self.slider.setValue)
        self.apply_button.clicked.connect(self.apply)
        self.read_button.clicked.connect(self.read)

        top = QHBoxLayout()
        top.addWidget(self.name_label)
        top.addWidget(self.slider, 1)
        top.addWidget(self.spin)
        top.addWidget(self.apply_button)
        top.addWidget(self.read_button)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 4, 0, 8)
        layout.addLayout(top)
        layout.addWidget(self.status_label)

    def set_value(self, value: VCPValue) -> None:
        current = value.current
        maximum = value.maximum or 100

        if current is None:
            self.set_unavailable("No interpreted numeric value.")
            return

        self.slider.blockSignals(True)
        self.spin.blockSignals(True)

        self.slider.setRange(0, maximum)
        self.spin.setRange(0, maximum)
        self.slider.setValue(current)
        self.spin.setValue(current)

        self.slider.blockSignals(False)
        self.spin.blockSignals(False)

        self.setEnabled(True)

        if value.name:
            self.status_label.setText(f"{value.name} · {current}/{maximum} · {value.backend}")
        else:
            self.status_label.setText(f"{current}/{maximum} · {value.backend}")

    def set_unavailable(self, reason: str) -> None:
        self.setEnabled(False)
        self.status_label.setText(f"Unavailable: {reason}")

    def value(self) -> int:
        return int(self.spin.value())

    def apply(self) -> None:
        self.apply_callback(self.value())

    def read(self) -> None:
        if self.read_callback is not None:
            self.read_callback()


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()

        self.backend = PlasmaDDCBackend()
        self.monitors = []
        self.current_profile = None

        self.setWindowTitle(APP_NAME)
        self.resize(1040, 720)

        self._build_ui()
        self._build_menu()
        self.refresh_monitors()

    # ------------------------------------------------------------------
    # UI base
    # ------------------------------------------------------------------

    def _build_ui(self) -> None:
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(14, 14, 14, 14)
        root.setSpacing(10)

        header = self._build_header()
        root.addWidget(header)

        splitter = QSplitter(Qt.Horizontal)

        self.sidebar = QListWidget()
        self.sidebar.setMinimumWidth(190)
        self.sidebar.setMaximumWidth(260)
        self.sidebar.currentRowChanged.connect(self._change_page)

        self.stack = QStackedWidget()

        splitter.addWidget(self.sidebar)
        splitter.addWidget(self.stack)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)

        root.addWidget(splitter, 1)

        self.setCentralWidget(central)
        self.statusBar().showMessage("Ready")

        self._create_pages()

    def _build_header(self) -> QWidget:
        box = QFrame()
        box.setFrameShape(QFrame.StyledPanel)

        layout = QHBoxLayout(box)
        layout.setContentsMargins(12, 10, 12, 10)

        title_box = QVBoxLayout()
        title = QLabel(APP_NAME)
        title.setStyleSheet("font-size: 20px; font-weight: 600;")
        subtitle = QLabel("Monitor control through DDC/CI")
        subtitle.setStyleSheet("opacity: 0.75;")
        title_box.addWidget(title)
        title_box.addWidget(subtitle)

        self.monitor_combo = QComboBox()
        self.monitor_combo.setMinimumWidth(340)
        self.monitor_combo.currentIndexChanged.connect(self.load_current_monitor)

        self.refresh_button = QPushButton("Detect Monitors")
        self.reload_button = QPushButton("Read Values")
        self.refresh_button.clicked.connect(self.refresh_monitors)
        self.reload_button.clicked.connect(self.load_current_monitor)

        layout.addLayout(title_box, 1)
        layout.addWidget(QLabel("Monitor:"))
        layout.addWidget(self.monitor_combo)
        layout.addWidget(self.refresh_button)
        layout.addWidget(self.reload_button)

        return box

    def _build_menu(self) -> None:
        refresh_action = QAction("Read Values", self)
        refresh_action.triggered.connect(self.load_current_monitor)

        detect_action = QAction("Detect Monitors", self)
        detect_action.triggered.connect(self.refresh_monitors)

        quit_action = QAction("Quit", self)
        quit_action.triggered.connect(self.close)

        app_menu = self.menuBar().addMenu("PlasmaDDC")
        app_menu.addAction(refresh_action)
        app_menu.addAction(detect_action)
        app_menu.addSeparator()
        app_menu.addAction(quit_action)

    def _create_pages(self) -> None:
        pages = [
            ("Overview", self._page_overview()),
            ("Image", self._page_image()),
            ("Color", self._page_color()),
            ("Audio", self._page_audio()),
            ("Input", self._page_input()),
            ("Diagnostics", self._page_diagnostics()),
        ]

        for title, widget in pages:
            item = QListWidgetItem(title)
            self.sidebar.addItem(item)
            self.stack.addWidget(widget)

        self.sidebar.setCurrentRow(0)

    def _page_wrapper(self, info: PageInfo) -> tuple[QWidget, QVBoxLayout]:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(16, 12, 16, 12)
        layout.setSpacing(12)

        title = QLabel(info.title)
        title.setStyleSheet("font-size: 18px; font-weight: 600;")

        subtitle = QLabel(info.subtitle)
        subtitle.setWordWrap(True)

        layout.addWidget(title)
        layout.addWidget(subtitle)

        return page, layout

    def _change_page(self, row: int) -> None:
        if row >= 0:
            self.stack.setCurrentIndex(row)

    # ------------------------------------------------------------------
    # Pages
    # ------------------------------------------------------------------

    def _page_overview(self) -> QWidget:
        page, layout = self._page_wrapper(
            PageInfo(
                "Monitor Overview",
                "Basic information detected by ddcutil and backend status.",
            )
        )

        group = QGroupBox("Current Monitor")
        form = QFormLayout(group)

        self.overview_label = QLabel("No monitor selected.")
        self.overview_label.setWordWrap(True)

        self.backend_label = QLabel("")
        self.backend_label.setWordWrap(True)

        form.addRow("Information:", self.overview_label)
        form.addRow("Backends:", self.backend_label)

        layout.addWidget(group)
        layout.addStretch(1)
        return page

    def _page_image(self) -> QWidget:
        page, layout = self._page_wrapper(
            PageInfo(
                "Image",
                "Basic brightness and contrast settings.",
            )
        )

        group = QGroupBox("Image Controls")
        group_layout = QVBoxLayout(group)

        self.brightness_control = ValueControl(
            "Brightness",
            self.apply_brightness,
            self.read_brightness,
        )
        self.contrast_control = ValueControl(
            "Contrast",
            self.apply_contrast,
            self.read_contrast,
        )

        group_layout.addWidget(self.brightness_control)
        group_layout.addWidget(self.contrast_control)

        layout.addWidget(group)
        layout.addStretch(1)
        return page

    def _page_color(self) -> QWidget:
        page, layout = self._page_wrapper(
            PageInfo(
                "Color",
                "Color temperature preset and RGB gains, if supported by the monitor.",
            )
        )

        preset_group = QGroupBox("Color temperature / preset")
        preset_layout = QHBoxLayout(preset_group)

        self.color_preset_combo = QComboBox()
        for label, value in common_color_presets():
            self.color_preset_combo.addItem(f"{label} · 0x{value:02X}", value)

        self.color_apply_button = QPushButton("Apply preset")
        self.color_read_button = QPushButton("Read")
        self.color_status_label = QLabel("")

        self.color_apply_button.clicked.connect(self.apply_color_preset)
        self.color_read_button.clicked.connect(self.read_color_preset)

        preset_layout.addWidget(self.color_preset_combo, 1)
        preset_layout.addWidget(self.color_apply_button)
        preset_layout.addWidget(self.color_read_button)
        preset_layout.addWidget(self.color_status_label)

        rgb_group = QGroupBox("RGB Gains")
        rgb_layout = QVBoxLayout(rgb_group)

        self.red_control = ValueControl("Red", self.apply_red, self.read_red)
        self.green_control = ValueControl("Green", self.apply_green, self.read_green)
        self.blue_control = ValueControl("Blue", self.apply_blue, self.read_blue)

        rgb_layout.addWidget(self.red_control)
        rgb_layout.addWidget(self.green_control)
        rgb_layout.addWidget(self.blue_control)

        layout.addWidget(preset_group)
        layout.addWidget(rgb_group)
        layout.addStretch(1)
        return page

    def _page_audio(self) -> QWidget:
        page, layout = self._page_wrapper(
            PageInfo(
                "Audio",
                "Monitor speaker/audio-output volume, if available.",
            )
        )

        group = QGroupBox("Volume")
        group_layout = QVBoxLayout(group)

        self.volume_control = ValueControl(
            "Volume",
            self.apply_volume,
            self.read_volume,
        )

        group_layout.addWidget(self.volume_control)

        layout.addWidget(group)
        layout.addStretch(1)
        return page

    def _page_input(self) -> QWidget:
        page, layout = self._page_wrapper(
            PageInfo(
                "Video Input",
                "Graphical monitor input control. Use it carefully: choosing an input without signal may blank the display.",
            )
        )

        group = QGroupBox("Input source")
        form = QFormLayout(group)

        self.input_combo = QComboBox()
        self.input_quick_buttons: list[QPushButton] = []
        sources = unique_input_sources()
        for label, value in sources:
            self.input_combo.addItem(f"{label} · 0x{value:02X}", value)

        self.input_apply_button = QPushButton("Switch Input")
        self.input_read_button = QPushButton("Read Current Input")
        self.input_status_label = QLabel("")
        self.input_status_label.setWordWrap(True)

        buttons = QWidget()
        buttons_layout = QHBoxLayout(buttons)
        buttons_layout.setContentsMargins(0, 0, 0, 0)
        buttons_layout.addWidget(self.input_apply_button)
        buttons_layout.addWidget(self.input_read_button)
        buttons_layout.addStretch(1)

        quick_box = QWidget()
        quick_layout = QGridLayout(quick_box)
        quick_layout.setContentsMargins(0, 0, 0, 0)
        quick_layout.setHorizontalSpacing(8)
        quick_layout.setVerticalSpacing(8)

        for i, (label, value) in enumerate(sources):
            button = QPushButton(label)
            button.setToolTip(f"Switch to {label} (0x{value:02X})")
            button.clicked.connect(partial(self.apply_input_source, value))
            self.input_quick_buttons.append(button)
            quick_layout.addWidget(button, i // 4, i % 4)

        self.custom_input_edit = QLineEdit()
        self.custom_input_edit.setPlaceholderText("Custom value, e.g. HDMI1, DP2, 0x11")
        self.custom_input_button = QPushButton("Switch Custom Input")
        self.custom_input_button.clicked.connect(self.apply_custom_input_source)

        custom_box = QWidget()
        custom_layout = QHBoxLayout(custom_box)
        custom_layout.setContentsMargins(0, 0, 0, 0)
        custom_layout.addWidget(self.custom_input_edit, 1)
        custom_layout.addWidget(self.custom_input_button)

        self.input_apply_button.clicked.connect(self.apply_input_source)
        self.input_read_button.clicked.connect(self.read_input_source)

        form.addRow("Selected input:", self.input_combo)
        form.addRow("", buttons)
        form.addRow("Quick switch:", quick_box)
        form.addRow("Custom input:", custom_box)
        form.addRow("Status:", self.input_status_label)

        layout.addWidget(group)
        layout.addStretch(1)
        return page

    def _page_diagnostics(self) -> QWidget:
        page, layout = self._page_wrapper(
            PageInfo(
                "Diagnostics",
                "Raw ddcutil capabilities and getvcp all output for debugging.",
            )
        )

        buttons = QHBoxLayout()
        self.capabilities_button = QPushButton("Read capabilities")
        self.getvcp_all_button = QPushButton("Read getvcp all")
        self.clear_diag_button = QPushButton("Clear")

        self.capabilities_button.clicked.connect(self.read_capabilities)
        self.getvcp_all_button.clicked.connect(self.read_getvcp_all)
        self.clear_diag_button.clicked.connect(lambda: self.diagnostics_text.clear())

        buttons.addWidget(self.capabilities_button)
        buttons.addWidget(self.getvcp_all_button)
        buttons.addWidget(self.clear_diag_button)
        buttons.addStretch(1)

        self.diagnostics_text = QTextEdit()
        self.diagnostics_text.setReadOnly(True)
        self.diagnostics_text.setLineWrapMode(QTextEdit.NoWrap)
        self.diagnostics_text.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

        layout.addLayout(buttons)
        layout.addWidget(self.diagnostics_text, 1)
        return page

    # ------------------------------------------------------------------
    # State Utilities
    # ------------------------------------------------------------------

    def current_monitor_index(self) -> int:
        data = self.monitor_combo.currentData()
        if data is None:
            return 0
        return int(data)

    def set_busy(self, busy: bool, message: str = "") -> None:
        self.setEnabled(not busy)
        QApplication.setOverrideCursor(Qt.WaitCursor if busy else Qt.ArrowCursor)

        if not busy:
            QApplication.restoreOverrideCursor()

        if message:
            self.statusBar().showMessage(message)

    def info(self, message: str) -> None:
        self.statusBar().showMessage(message, 7000)

    def show_error(self, message: str) -> None:
        self.statusBar().showMessage(message, 10000)
        QMessageBox.warning(self, APP_NAME, message)

    def run_safe(self, operation: Callable[[], None], success: str | None = None) -> None:
        try:
            operation()
            if success:
                self.info(success)
        except PlasmaDDCError as exc:
            self.show_error(str(exc))
        except Exception as exc:
            self.show_error(f"Unexpected error: {exc}")

    def select_combo_by_value(self, combo: QComboBox, value: int) -> None:
        for i in range(combo.count()):
            if int(combo.itemData(i)) == int(value):
                combo.setCurrentIndex(i)
                return

    # ------------------------------------------------------------------
    # Monitor and Profile Loading
    # ------------------------------------------------------------------

    def refresh_monitors(self) -> None:
        def op() -> None:
            self.monitors = self.backend.refresh_monitors()

            self.monitor_combo.blockSignals(True)
            self.monitor_combo.clear()

            for monitor in self.monitors:
                self.monitor_combo.addItem(monitor.label, monitor.index)

            self.monitor_combo.blockSignals(False)

            if self.monitors:
                self.monitor_combo.setCurrentIndex(0)
                self.load_current_monitor()
            else:
                self.disable_all_controls("No monitors detected.")
                self.overview_label.setText("No monitors detected.")

        self.run_safe(op, "Monitors updated.")

    def load_current_monitor(self) -> None:
        if not self.monitors:
            return

        def op() -> None:
            index = self.current_monitor_index()
            self.current_profile = self.backend.build_monitor_profile(index)
            self.update_from_profile()

        self.run_safe(op, "Values read.")

    def disable_all_controls(self, reason: str) -> None:
        for control in (
            self.brightness_control,
            self.contrast_control,
            self.volume_control,
            self.red_control,
            self.green_control,
            self.blue_control,
        ):
            control.set_unavailable(reason)

        self.color_preset_combo.setEnabled(False)
        self.color_apply_button.setEnabled(False)
        self.color_read_button.setEnabled(False)
        self.color_status_label.setText(reason)

        self.input_combo.setEnabled(False)
        self.input_apply_button.setEnabled(False)
        self.input_read_button.setEnabled(False)
        self.custom_input_edit.setEnabled(False)
        self.custom_input_button.setEnabled(False)
        for button in self.input_quick_buttons:
            button.setEnabled(False)
        self.input_status_label.setText(reason)

    def update_from_profile(self) -> None:
        if self.current_profile is None:
            return

        profile = self.current_profile
        monitor = profile.monitor

        self.overview_label.setText(
            "\n".join(
                [
                    f"Label: {monitor.label}",
                    f"Display: {monitor.display_number}",
                    f"Bus: {monitor.bus_path or monitor.bus_number}",
                    f"DRM Connector: {monitor.drm_connector}",
                    f"Manufacturer: {monitor.manufacturer_id}",
                    f"Model: {monitor.model_name}",
                    f"Serial: {monitor.serial_number}",
                ]
            )
        )

        self.backend_label.setText(
            "\n".join(
                [
                    f"ddcutil available: {self.backend.ddcutil_available()}",
                    f"monitorcontrol available: {self.backend.monitorcontrol_available()}",
                    f"monitorcontrol reliable for basic VCPs: {self.backend.monitorcontrol_reliable(monitor.index)}",
                    "Active backend for controls: ddcutil",
                ]
            )
        )

        self.update_value_control(
            self.brightness_control,
            "brightness",
            "Brightness unavailable.",
        )
        self.update_value_control(
            self.contrast_control,
            "contrast",
            "Contrast unavailable.",
        )
        self.update_value_control(
            self.volume_control,
            "volume",
            "Volume unavailable.",
        )
        self.update_value_control(
            self.red_control,
            "red_gain",
            "Red unavailable.",
        )
        self.update_value_control(
            self.green_control,
            "green_gain",
            "Green unavailable.",
        )
        self.update_value_control(
            self.blue_control,
            "blue_gain",
            "Blue unavailable.",
        )

        self.update_color_preset()
        self.update_input_source()

        diag_parts = []
        if profile.capabilities_text:
            diag_parts.append("===== capabilities =====")
            diag_parts.append(profile.capabilities_text)

        if profile.getvcp_all_text:
            diag_parts.append("")
            diag_parts.append("===== getvcp all =====")
            diag_parts.append(profile.getvcp_all_text)

        if profile.errors:
            diag_parts.append("")
            diag_parts.append("===== errors/unavailable =====")
            for key, value in profile.errors.items():
                diag_parts.append(f"{key}: {value}")

        self.diagnostics_text.setPlainText("\n".join(diag_parts))

    def update_value_control(self, control: ValueControl, key: str, fallback: str) -> None:
        if self.current_profile is None:
            control.set_unavailable("No profile loaded.")
            return

        value = self.current_profile.values.get(key)

        if value is not None:
            control.set_value(value)
            return

        reason = self.current_profile.errors.get(key, fallback)
        control.set_unavailable(reason)

    def update_color_preset(self) -> None:
        if self.current_profile is None:
            return

        value = self.current_profile.values.get("color_preset")

        if value is None:
            self.color_preset_combo.setEnabled(False)
            self.color_apply_button.setEnabled(False)
            self.color_read_button.setEnabled(False)
            self.color_status_label.setText(
                self.current_profile.errors.get("color_preset", "Unavailable.")
            )
            return

        self.color_preset_combo.setEnabled(True)
        self.color_apply_button.setEnabled(True)
        self.color_read_button.setEnabled(True)

        if value.selector is not None:
            self.select_combo_by_value(self.color_preset_combo, value.selector)
            self.color_status_label.setText(value.as_text())
        else:
            self.color_status_label.setText(value.as_text())

    def update_input_source(self) -> None:
        if self.current_profile is None:
            return

        value = self.current_profile.values.get("input_source")

        if value is None:
            self.input_combo.setEnabled(False)
            self.input_apply_button.setEnabled(False)
            self.input_read_button.setEnabled(False)
            self.custom_input_edit.setEnabled(False)
            self.custom_input_button.setEnabled(False)
            for button in self.input_quick_buttons:
                button.setEnabled(False)
            self.input_status_label.setText(
                self.current_profile.errors.get("input_source", "Unavailable.")
            )
            return

        self.input_combo.setEnabled(True)
        self.input_apply_button.setEnabled(True)
        self.input_read_button.setEnabled(True)
        self.custom_input_edit.setEnabled(True)
        self.custom_input_button.setEnabled(True)
        for button in self.input_quick_buttons:
            button.setEnabled(True)

        if value.selector is not None:
            self.select_combo_by_value(self.input_combo, value.selector)
            self.input_status_label.setText(value.as_text())
        else:
            self.input_status_label.setText(value.as_text())

    # ------------------------------------------------------------------
    # Individual Reads
    # ------------------------------------------------------------------

    def read_brightness(self) -> None:
        self.run_safe(lambda: self.brightness_control.set_value(self.backend.get_brightness(self.current_monitor_index())), "Brightness read.")

    def read_contrast(self) -> None:
        self.run_safe(lambda: self.contrast_control.set_value(self.backend.get_contrast(self.current_monitor_index())), "Contrast read.")

    def read_volume(self) -> None:
        self.run_safe(lambda: self.volume_control.set_value(self.backend.get_volume(self.current_monitor_index())), "Volume read.")

    def read_red(self) -> None:
        self.run_safe(lambda: self.red_control.set_value(self.backend.get_rgb_gain(self.current_monitor_index(), "red")), "Red read.")

    def read_green(self) -> None:
        self.run_safe(lambda: self.green_control.set_value(self.backend.get_rgb_gain(self.current_monitor_index(), "green")), "Green read.")

    def read_blue(self) -> None:
        self.run_safe(lambda: self.blue_control.set_value(self.backend.get_rgb_gain(self.current_monitor_index(), "blue")), "Blue read.")

    def read_color_preset(self) -> None:
        def op() -> None:
            value = self.backend.get_color_preset(self.current_monitor_index())
            if value.selector is not None:
                self.select_combo_by_value(self.color_preset_combo, value.selector)
            self.color_status_label.setText(value.as_text())

        self.run_safe(op, "Color preset read.")

    def read_input_source(self) -> None:
        def op() -> None:
            value = self.backend.get_input_source(self.current_monitor_index())
            if value.selector is not None:
                self.select_combo_by_value(self.input_combo, value.selector)
            self.input_status_label.setText(value.as_text())

        self.run_safe(op, "Input read.")

    def read_capabilities(self) -> None:
        def op() -> None:
            text = self.backend.get_capabilities_text(self.current_monitor_index())
            self.diagnostics_text.setPlainText(text)

        self.run_safe(op, "Capabilities read.")

    def read_getvcp_all(self) -> None:
        def op() -> None:
            text = self.backend.get_all_vcps_text(self.current_monitor_index())
            self.diagnostics_text.setPlainText(text)

        self.run_safe(op, "getvcp all read.")

    # ------------------------------------------------------------------
    # Writes
    # ------------------------------------------------------------------

    def apply_brightness(self, value: int) -> None:
        self.run_safe(
            lambda: self.backend.set_brightness(self.current_monitor_index(), value),
            f"Brightness applied: {value}",
        )

    def apply_contrast(self, value: int) -> None:
        self.run_safe(
            lambda: self.backend.set_contrast(self.current_monitor_index(), value),
            f"Contrast applied: {value}",
        )

    def apply_volume(self, value: int) -> None:
        self.run_safe(
            lambda: self.backend.set_volume(self.current_monitor_index(), value),
            f"Volume applied: {value}",
        )

    def apply_red(self, value: int) -> None:
        self.run_safe(
            lambda: self.backend.set_rgb_gain(self.current_monitor_index(), "red", value),
            f"Red applied: {value}",
        )

    def apply_green(self, value: int) -> None:
        self.run_safe(
            lambda: self.backend.set_rgb_gain(self.current_monitor_index(), "green", value),
            f"Green applied: {value}",
        )

    def apply_blue(self, value: int) -> None:
        self.run_safe(
            lambda: self.backend.set_rgb_gain(self.current_monitor_index(), "blue", value),
            f"Blue applied: {value}",
        )

    def apply_color_preset(self) -> None:
        value = int(self.color_preset_combo.currentData())

        self.run_safe(
            lambda: self.backend.set_color_preset(self.current_monitor_index(), value),
            f"Color preset applied: {color_preset_label(value)}",
        )

        self.read_color_preset()

    def apply_custom_input_source(self) -> None:
        text = self.custom_input_edit.text().strip()
        if not text:
            self.show_error("Enter an input alias or VCP value first.")
            return

        try:
            value = input_source_to_int(text)
        except ValueError as exc:
            self.show_error(str(exc))
            return

        self.apply_input_source(value)

    def apply_input_source(self, raw_value: int | None = None) -> None:
        value = int(raw_value if raw_value is not None else self.input_combo.currentData())
        label = input_source_label(value)

        answer = QMessageBox.warning(
            self,
            APP_NAME,
            (
                f"You are about to switch the monitor input to:\n\n"
                f"{label} · 0x{value:02X}\n\n"
                "If that input has no signal, the picture may disappear until you switch "
                "back using the monitor's physical buttons.\n\n"
                "Do you want to continue?"
            ),
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )

        if answer != QMessageBox.Yes:
            self.info("Input switch cancelled.")
            return

        self.run_safe(
            lambda: self.backend.set_input_source(self.current_monitor_index(), value),
            f"Input applied: {label}",
        )
        self.select_combo_by_value(self.input_combo, value)


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)

    window = MainWindow()
    window.show()

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
