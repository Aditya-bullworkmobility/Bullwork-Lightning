import os
import re
import glob
import json
import subprocess
from dataclasses import dataclass
from typing import List, Optional, Tuple

from PyQt5.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QTextEdit, QListWidget, QListWidgetItem, QFrame, QMessageBox, QTabWidget
)
from PyQt5.QtCore import QProcess, Qt


# ---------------- CONFIG ----------------
RCLONE_REMOTE = "gdrive"
RCLONE_FOLDER = "jetson_acu_images"

# Keep your existing cache location (hidden). Change if you want visible folder.
DOWNLOAD_DIR = os.path.expanduser("~/.cache/jetson-flasher/downloads")

# NOTE: If you're testing from folder (not .deb), /opt won't exist.
# This resolves toolkit dir automatically for both dev folder and /opt install.
def resolve_toolkit_dir() -> str:
    local = os.path.dirname(os.path.abspath(__file__))
    opt = "/opt/Bullwork_lightning"
    if os.path.isfile(os.path.join(opt, "flash_from_zip.sh")):
        return opt
    return local

TOOLKIT_DIR = resolve_toolkit_dir()


# ---------------- DATA MODEL ----------------
@dataclass
class ZipCandidate:
    path: str
    version_str: str
    version_tuple: Tuple[int, ...]
    mtime: float


# ---------------- HELPERS ----------------
def ensure_download_dir():
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)


def norm_name(s: str) -> str:
    return s.lower().replace(" ", "_")


def _extract_version_from_name(filename: str) -> Tuple[str, Tuple[int, ...]]:
    """
    Extract versions like v2.2, 2.2, 2.2.1 from filename.
    """
    m = re.search(r'(?i)(?:^|[^0-9])v?(\d+(?:\.\d+){1,3})(?:[^0-9]|$)', filename)
    if not m:
        return "unknown", ()
    v = m.group(1)
    tup = tuple(int(x) for x in v.split("."))
    return v, tup


def list_drive_zip_candidates() -> List[ZipCandidate]:
    """
    Lists zip files inside gdrive:jetson_acu_images and returns ZipCandidate list
    sorted latest version on top.
    """
    cmd = ["rclone", "lsjson", f"{RCLONE_REMOTE}:{RCLONE_FOLDER}"]
    out = subprocess.check_output(cmd, text=True, errors="ignore")
    items = json.loads(out)

    found: List[ZipCandidate] = []
    for it in items:
        if it.get("IsDir"):
            continue
        name = it.get("Name", "")
        if not name.lower().endswith(".zip"):
            continue
        if "acu_platform" not in norm_name(name):
            continue

        vstr, vtup = _extract_version_from_name(name)
        found.append(ZipCandidate(
            path=name,  # remote filename within that folder
            version_str=vstr,
            version_tuple=vtup,
            mtime=0.0
        ))

    def sort_key(z: ZipCandidate):
        known = 1 if z.version_tuple else 0
        vt = z.version_tuple + (0,) * (4 - len(z.version_tuple))
        return (known, vt)

    found.sort(key=sort_key, reverse=True)
    return found


def drive_download_command(remote_filename: str, local_path: str) -> List[str]:
    ensure_download_dir()
    src = f"{RCLONE_REMOTE}:{RCLONE_FOLDER}/{remote_filename}"
    return ["rclone", "copyto", src, local_path, "--progress"]


def local_toolkit_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def find_acu_platform_zips() -> List[ZipCandidate]:
    """
    Searches common directories for acu_platform ZIPs (space/underscore ok),
    including DOWNLOAD_DIR (Drive downloads).
    """
    user = os.getenv("USER") or ""

    def norm(s: str) -> str:
        return s.lower().replace(" ", "_")

    search_dirs = [
        local_toolkit_dir(),
        DOWNLOAD_DIR,
        os.path.expanduser("~/Downloads"),
        os.path.expanduser("~/Desktop"),
        os.path.expanduser("~"),
        "/mnt",
        f"/media/{user}" if user else "/media",
        "/media",
    ]

    found: List[ZipCandidate] = []
    seen = set()

    for base in search_dirs:
        if not base or not os.path.isdir(base):
            continue

        patterns = [
            os.path.join(base, "**", "*.zip"),
            os.path.join(base, "**", "*.ZIP"),
        ]

        for pat in patterns:
            for path in glob.glob(pat, recursive=True):
                if not os.path.isfile(path):
                    continue

                real = os.path.realpath(path)
                if real in seen:
                    continue
                seen.add(real)

                fname = os.path.basename(real)
                if "acu_platform" not in norm(fname):
                    continue

                vstr, vtup = _extract_version_from_name(fname)
                found.append(ZipCandidate(
                    path=real,
                    version_str=vstr,
                    version_tuple=vtup,
                    mtime=os.path.getmtime(real),
                ))

    def sort_key(z: ZipCandidate):
        known = 1 if z.version_tuple else 0
        vt = z.version_tuple + (0,) * (4 - len(z.version_tuple))
        return (known, vt, z.mtime)

    found.sort(key=sort_key, reverse=True)
    return found


def is_jetson_in_recovery() -> bool:
    """
    Detect Jetson Force-Recovery via lsusb.
    NVIDIA vendor id commonly shows as 0955:xxxx
    """
    try:
        out = subprocess.check_output(["lsusb"], text=True, errors="ignore")
        return ("0955:" in out) or ("NVIDIA Corp." in out)
    except Exception:
        return False


# ---------------- UI STYLE ----------------
APP_QSS = """
QWidget { background-color: #0b0f14; color: #e6edf3; font-size: 12px; }
QLabel#Title { font-size: 20px; font-weight: 700; color: #d7ffe6; }
QLabel#SubTitle { color: #a7b3c0; }
QFrame#Sidebar { background-color: #071018; border: 1px solid #0f2436; border-radius: 12px; }
QFrame#MainCard { background-color: #0a141e; border: 1px solid #0f2436; border-radius: 12px; }
QPushButton { background-color: #113a2b; border: 1px solid #1f6f4a; border-radius: 10px; padding: 10px 14px; font-weight: 600; }
QPushButton:hover { background-color: #145036; }
QPushButton:disabled { background-color: #1a222c; border: 1px solid #2b3642; color: #768392; }
QListWidget { background-color: #071018; border: 1px solid #0f2436; border-radius: 10px; padding: 6px; }
QListWidget::item { padding: 10px; margin: 4px; border-radius: 10px; background-color: #0a141e; border: 1px solid #0f2436; }
QListWidget::item:selected { background-color: #113a2b; border: 1px solid #2bd576; }
QTextEdit { background-color: #071018; border: 1px solid #0f2436; border-radius: 10px; padding: 8px; font-family: monospace; font-size: 11px; }
"""


class Flasher(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Jetson Flasher")
        self.resize(1100, 720)

        self.proc: Optional[QProcess] = None
        self.zips: List[ZipCandidate] = []
        self.drive_zips: List[ZipCandidate] = []

        # STOP support
        self.current_job: Optional[str] = None            # "download" or "flash"
        self.current_download_path: Optional[str] = None  # local path for current download

        # --------- Layout root ----------
        root = QHBoxLayout(self)
        root.setContentsMargins(18, 18, 18, 18)
        root.setSpacing(14)

        # --------- Sidebar ----------
        sidebar = QFrame()
        sidebar.setObjectName("Sidebar")
        sb = QVBoxLayout(sidebar)
        sb.setContentsMargins(14, 14, 14, 14)
        sb.setSpacing(10)

        title = QLabel("Jetson Flasher")
        title.setObjectName("Title")
        subtitle = QLabel(f"Toolkit: {TOOLKIT_DIR}\nDownload from Drive if needed, then flash (local).")
        subtitle.setObjectName("SubTitle")

        self.btn_check = QPushButton("Check Recovery Mode")
        self.recovery_status = QLabel("Recovery: Unknown")
        self.recovery_status.setObjectName("SubTitle")

        sb.addWidget(title)
        sb.addWidget(subtitle)
        sb.addSpacing(8)
        sb.addWidget(self.btn_check)
        sb.addWidget(self.recovery_status)
        sb.addStretch(1)

        # --------- Main card ----------
        main = QFrame()
        main.setObjectName("MainCard")
        mc = QVBoxLayout(main)
        mc.setContentsMargins(14, 14, 14, 14)
        mc.setSpacing(12)

        header = QLabel("Images / Archives")
        header.setObjectName("SubTitle")

        # --------- Tabs ----------
        self.tabs = QTabWidget()

        # --- Local Tab ---
        self.local_tab = QWidget()
        local_layout = QVBoxLayout(self.local_tab)
        local_layout.setContentsMargins(0, 0, 0, 0)
        local_layout.setSpacing(10)

        self.btn_refresh_local = QPushButton("Refresh Local ZIP list")
        self.local_list_widget = QListWidget()
        self.local_list_widget.setSelectionMode(QListWidget.SingleSelection)

        local_layout.addWidget(self.btn_refresh_local)
        local_layout.addWidget(self.local_list_widget, stretch=1)
        self.tabs.addTab(self.local_tab, "Local ZIPs")

        # --- Drive Tab ---
        self.drive_tab = QWidget()
        drive_layout = QVBoxLayout(self.drive_tab)
        drive_layout.setContentsMargins(0, 0, 0, 0)
        drive_layout.setSpacing(10)

        self.btn_refresh_drive = QPushButton("Refresh Drive list")
        self.drive_list_widget = QListWidget()
        self.drive_list_widget.setSelectionMode(QListWidget.SingleSelection)
        self.btn_download = QPushButton("Download Selected (Drive → Local)")
        self.btn_stop = QPushButton("STOP (Cancel current job)")
        self.btn_stop.setEnabled(False)

        drive_layout.addWidget(self.btn_refresh_drive)
        drive_layout.addWidget(self.drive_list_widget, stretch=1)
        drive_layout.addWidget(self.btn_download)
        drive_layout.addWidget(self.btn_stop)

        self.tabs.addTab(self.drive_tab, "Google Drive")

        # Buttons row (Flash)
        btn_row = QHBoxLayout()
        self.btn_flash = QPushButton("FLASH Selected (Local)")
        self.btn_flash.setMinimumHeight(44)
        self.btn_flash.setEnabled(False)
        btn_row.addWidget(self.btn_flash)
        btn_row.addStretch(1)

        # Status + logs
        self.status = QLabel("Status: Idle")
        self.status.setObjectName("SubTitle")

        self.log = QTextEdit()
        self.log.setReadOnly(True)

        mc.addWidget(header)
        mc.addWidget(self.tabs, stretch=1)
        mc.addLayout(btn_row)
        mc.addWidget(self.status)
        mc.addWidget(self.log, stretch=1)

        root.addWidget(sidebar, stretch=0)
        root.addWidget(main, stretch=1)

        self.setStyleSheet(APP_QSS)

        # --------- Signals ----------
        self.btn_check.clicked.connect(self.check_recovery)

        self.btn_refresh_local.clicked.connect(self.refresh_zip_list)
        self.local_list_widget.itemSelectionChanged.connect(self.on_local_selection_changed)

        self.btn_refresh_drive.clicked.connect(self.refresh_drive_list)
        self.btn_download.clicked.connect(self.download_selected_drive_zip)

        self.btn_stop.clicked.connect(self.stop_current_job)

        self.btn_flash.clicked.connect(self.flash_selected)

        # Initial load
        self.refresh_zip_list()

    def append_log(self, s: str):
        self.log.append(s.rstrip())

    def set_busy(self, busy: bool):
        self.btn_check.setEnabled(not busy)
        self.btn_refresh_local.setEnabled(not busy)
        self.btn_refresh_drive.setEnabled(not busy)
        self.btn_download.setEnabled(not busy)

        self.btn_flash.setEnabled((not busy) and (self.local_list_widget.currentRow() >= 0))
        self.btn_stop.setEnabled(busy and (self.proc is not None))

        self.btn_flash.setText("FLASH Selected (Local)" if not busy else "WORKING...")

    # ---------------- STOP ----------------
    def stop_current_job(self):
        if not self.proc:
            return

        self.append_log("\n⛔ STOP pressed. Cancelling process...")

        # Graceful terminate then force kill if needed
        self.proc.terminate()
        if not self.proc.waitForFinished(1500):
            self.append_log("Force killing process...")
            self.proc.kill()

        # If it was a download, delete partial/unwanted zip
        if self.current_job == "download" and self.current_download_path:
            try:
                if os.path.exists(self.current_download_path):
                    os.remove(self.current_download_path)
                    self.append_log(f"🗑 Deleted unwanted ZIP: {self.current_download_path}")
            except Exception as e:
                self.append_log(f"WARNING: Could not delete ZIP: {e}")

        self.current_job = None
        self.current_download_path = None
        self.proc = None

        self.status.setText("Status: Cancelled by user ❌")
        self.set_busy(False)

    # ---------------- LOCAL ----------------
    def refresh_zip_list(self):
        self.log.clear()
        self.status.setText("Status: Scanning for local ZIPs (acu_platform / acu platform) ...")
        self.local_list_widget.clear()

        self.zips = find_acu_platform_zips()

        if not self.zips:
            self.status.setText("Status: No local acu_platform ZIP found ❌")
            self.append_log("No local matches found.")
            self.append_log("Tip: Use Google Drive tab → download → then flash.")
            self.btn_flash.setEnabled(False)
            return

        for z in self.zips:
            fn = os.path.basename(z.path)
            v = z.version_str
            label = f"v{v}" if v != "unknown" else "version: unknown"
            item_text = f"{label}  —  {fn}\n{z.path}"
            item = QListWidgetItem(item_text)
            item.setData(Qt.UserRole, z.path)
            self.local_list_widget.addItem(item)

        self.local_list_widget.setCurrentRow(0)
        self.status.setText(f"Status: Found {len(self.zips)} local ZIP(s). Latest selected ✅")
        self.btn_flash.setEnabled(True)

    def on_local_selection_changed(self):
        self.btn_flash.setEnabled(self.local_list_widget.currentRow() >= 0 and (self.proc is None))

    # ---------------- DRIVE ----------------
    def refresh_drive_list(self):
        self.log.clear()
        self.status.setText(f"Status: Reading ZIP list from Drive: {RCLONE_REMOTE}:{RCLONE_FOLDER} ...")
        self.drive_list_widget.clear()

        try:
            self.drive_zips = list_drive_zip_candidates()
        except Exception as e:
            self.status.setText("Status: Drive list failed ❌")
            self.append_log("ERROR: Could not list Google Drive folder.")
            self.append_log(str(e))
            self.append_log(f"Try: rclone ls {RCLONE_REMOTE}:{RCLONE_FOLDER}")
            return

        if not self.drive_zips:
            self.status.setText("Status: No acu_platform ZIPs found on Drive ❌")
            self.append_log("No Drive matches found.")
            return

        for z in self.drive_zips:
            fn = z.path
            v = z.version_str
            label = f"v{v}" if v != "unknown" else "version: unknown"
            item = QListWidgetItem(f"{label}  —  {fn}\n{RCLONE_REMOTE}:{RCLONE_FOLDER}")
            item.setData(Qt.UserRole, fn)
            self.drive_list_widget.addItem(item)

        self.drive_list_widget.setCurrentRow(0)
        self.status.setText(f"Status: Found {len(self.drive_zips)} Drive ZIP(s) ✅")

    def download_selected_drive_zip(self):
        row = self.drive_list_widget.currentRow()
        if row < 0:
            QMessageBox.warning(self, "No selection", "Select a ZIP in the Google Drive tab first.")
            return

        remote_filename = self.drive_zips[row].path
        ensure_download_dir()
        local_path = os.path.join(DOWNLOAD_DIR, os.path.basename(remote_filename))

        self.log.clear()
        self.append_log(f"Downloading from Drive:\n{RCLONE_REMOTE}:{RCLONE_FOLDER}/{remote_filename}")
        self.append_log(f"To local cache:\n{local_path}\n")

        cmd = drive_download_command(remote_filename, local_path)

        # Track job for STOP + delete on cancel
        self.current_job = "download"
        self.current_download_path = local_path

        self.status.setText("Status: Downloading from Drive…")

        self.proc = QProcess(self)
        self.proc.setProgram(cmd[0])
        self.proc.setArguments(cmd[1:])
        self.proc.readyReadStandardOutput.connect(self.on_stdout)
        self.proc.readyReadStandardError.connect(self.on_stderr)
        self.proc.finished.connect(lambda code, st: self.on_download_finished(code, local_path))

        self.proc.start()
        self.set_busy(True)  # <-- move here (after self.proc exists)

    def on_download_finished(self, code: int, local_path: str):
        self.proc = None
        self.set_busy(False)

        if code != 0:
            self.status.setText(f"Status: Download cancelled/failed ❌ (exit {code})")
            self.append_log(f"\n❌ Download ended (exit code {code}).")

            # Remove partial/unwanted file
            try:
                if os.path.exists(local_path):
                    os.remove(local_path)
                    self.append_log(f"🗑 Removed partial/unwanted ZIP: {local_path}")
            except Exception as e:
                self.append_log(f"WARNING: Could not delete partial ZIP: {e}")

            self.current_job = None
            self.current_download_path = None
            return

        self.status.setText("Status: Download complete ✅")
        self.append_log(f"\n✅ Download complete: {local_path}")

        self.current_job = None
        self.current_download_path = None

        # Refresh local list + switch to Local tab
        self.refresh_zip_list()
        self.tabs.setCurrentIndex(0)

    # ---------------- FLASH ----------------
    def check_recovery(self):
        ok = is_jetson_in_recovery()
        if ok:
            self.recovery_status.setText("Recovery: Detected ✅ (0955)")
            self.status.setText("Status: Jetson in recovery ✅")
        else:
            self.recovery_status.setText("Recovery: Not detected ❌")
            self.status.setText("Status: Put Jetson in recovery and retry ❌")

    def flash_selected(self):
        row = self.local_list_widget.currentRow()
        if row < 0:
            QMessageBox.warning(self, "No selection", "Select a LOCAL ZIP first (download from Drive if needed).")
            return

        zip_path = self.zips[row].path
        flash_script = os.path.join(TOOLKIT_DIR, "flash_from_zip.sh")

        self.log.clear()
        self.append_log(f"Selected LOCAL ZIP:\n{zip_path}\n")

        if not os.path.isfile(flash_script):
            self.status.setText("Status: flash_from_zip.sh missing ❌")
            self.append_log(f"ERROR: {flash_script} not found.")
            return

        if not os.path.isfile(zip_path):
            self.status.setText("Status: ZIP missing ❌")
            self.append_log("ERROR: Selected ZIP file no longer exists.")
            return

        if not is_jetson_in_recovery():
            self.status.setText("Status: Jetson NOT in recovery ❌")
            self.append_log("ERROR: Jetson not detected in force-recovery mode.")
            self.append_log("Hint: `lsusb | grep 0955` should show a device.")
            return

        self.status.setText("Status: Flashing… (admin prompt will appear)")
        
        # Track job (STOP will cancel the flashing process too)
        self.current_job = "flash"
        self.current_download_path = None

        cmd = [
            "pkexec",
            "bash",
            "-lc",
            f'cd "{TOOLKIT_DIR}" && chmod +x ./flash_from_zip.sh && ./flash_from_zip.sh "{zip_path}"'
        ]

        self.proc = QProcess(self)
        self.proc.setProgram(cmd[0])
        self.proc.setArguments(cmd[1:])
        self.proc.readyReadStandardOutput.connect(self.on_stdout)
        self.proc.readyReadStandardError.connect(self.on_stderr)
        self.proc.finished.connect(self.on_flash_finished)
        self.proc.start()
        self.set_busy(True)


    def on_stdout(self):
        if not self.proc:
            return
        data = bytes(self.proc.readAllStandardOutput()).decode(errors="ignore")
        if data:
            self.append_log(data)

    def on_stderr(self):
        if not self.proc:
            return
        data = bytes(self.proc.readAllStandardError()).decode(errors="ignore")
        if data:
            self.append_log(data)

def closeEvent(self, event):
    # If something is running, stop it before closing
    if self.proc is not None:
        try:
            self.proc.terminate()
            if not self.proc.waitForFinished(1000):
                self.proc.kill()
        except Exception:
            pass
    event.accept()

    def on_flash_finished(self, code: int, _status):
        self.proc = None
        self.set_busy(False)

        self.current_job = None
        self.current_download_path = None

        if code == 0:
            self.status.setText("Status: Flash complete ✅ Reboot/power-cycle Jetson.")
            self.append_log("\n✅ Done. Reboot/power-cycle the Jetson now.")
        else:
            self.status.setText(f"Status: Flash FAILED / Cancelled ❌ (exit code {code})")
            self.append_log(f"\n❌ Flash ended with exit code {code}. Check logs above.")


if __name__ == "__main__":
    app = QApplication([])
    w = Flasher()
    w.show()
    app.exec_()