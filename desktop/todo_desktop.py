"""할 일 노트 — PC 설치판 (Docker 없이).

하나의 프로세스가 다음을 모두 맡는다.
  - API + 웹 화면 서버 (FastAPI, http://127.0.0.1:8080)  ← 위젯 기본 주소와 같음
  - 데이터: SQLite 파일 %APPDATA%\\TodoNote\\todos.db
  - 트레이 아이콘 (열기 / 달력 위젯 / 휴대폰 접속 허용 / 종료)
  - 바탕화면 달력 위젯(widget.ps1) 실행

옵션
  --background         창을 열지 않고 트레이로만 시작 (로그인 자동 실행용)
  --no-tray            트레이·창·위젯 없이 서버만 (테스트용, Ctrl+C 로 종료)
  --port N             포트 (기본: 설정 파일의 port, 없으면 8080)
  --import-from URL    다른 서버(예: Docker 판 http://localhost:8080/api)의 할 일을 가져와 합치고 종료
환경변수 TODO_DATA_DIR 로 데이터 폴더를 바꿀 수 있다.
"""
import argparse
import ctypes
import json
import logging
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from pathlib import Path

APP_TITLE = "할 일 노트"
FROZEN = getattr(sys, "frozen", False)
BASE = Path(sys._MEIPASS) if FROZEN else Path(__file__).resolve().parent.parent

if FROZEN:
    WEB_DIR = BASE / "web"
    WIDGET_PS1 = BASE / "widget" / "widget.ps1"
    ICON_PNG = BASE / "icon.png"
else:
    sys.path.insert(0, str(BASE / "api"))
    WEB_DIR = BASE / "web" / "public"
    WIDGET_PS1 = BASE / "widget" / "widget.ps1"
    ICON_PNG = BASE / "desktop" / "build" / "icon.png"

DATA_DIR = Path(os.environ.get("TODO_DATA_DIR") or Path(os.environ.get("APPDATA", Path.home())) / "TodoNote")
SETTINGS_PATH = DATA_DIR / "desktop.json"
DB_PATH = DATA_DIR / "todos.db"
DEFAULTS = {"port": 8080, "lan": False, "widget": True}

log = logging.getLogger("todo-desktop")


# ---------- 설정 ----------
def load_settings():
    s = dict(DEFAULTS)
    try:
        s.update(json.loads(SETTINGS_PATH.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass
    return s


def save_settings(s):
    try:
        SETTINGS_PATH.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        log.exception("설정 저장 실패")


# ---------- 유틸 ----------
def message(text, error=False):
    if os.name == "nt":
        ctypes.windll.user32.MessageBoxW(None, text, APP_TITLE, 0x10 if error else 0x40)
    else:
        print(text, file=sys.stderr)


def single_instance():
    """이미 실행 중이면 False."""
    if os.name != "nt":
        return True
    ctypes.windll.kernel32.CreateMutexW(None, False, "Local\\TodoNoteDesktop")
    return ctypes.windll.kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS


def healthy(port, timeout=1.0):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=timeout) as r:
            return r.status == 200
    except OSError:
        return False


def port_free(port):
    with socket.socket() as s:
        try:
            s.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def lan_ip():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # 패킷은 보내지 않음, 경로만 확인
            return s.getsockname()[0]
    except OSError:
        return None


def open_window(port):
    """주소창 없는 앱 창으로 열기 (Edge/Chrome --app), 없으면 기본 브라우저."""
    url = f"http://127.0.0.1:{port}/"
    candidates = []
    for env in ("PROGRAMFILES(X86)", "PROGRAMFILES", "LOCALAPPDATA"):
        root = os.environ.get(env)
        if root:
            candidates += [Path(root) / "Microsoft/Edge/Application/msedge.exe",
                           Path(root) / "Google/Chrome/Application/chrome.exe"]
    for exe in candidates:
        if exe.is_file():
            subprocess.Popen([str(exe), f"--app={url}"], close_fds=True)
            return
    webbrowser.open(url)


# ---------- 서버 ----------
def build_app():
    os.environ["DATABASE_URL"] = "sqlite:///" + str(DB_PATH)
    from fastapi.staticfiles import StaticFiles
    from app.main import create_app  # DATABASE_URL 을 정한 뒤에 import

    application = create_app(prefix="/api", root_path="")
    application.mount("/", StaticFiles(directory=str(WEB_DIR), html=True), name="web")
    return application


class ServerThread:
    def __init__(self, application, port):
        self.application = application
        self.port = port
        self.server = None
        self.thread = None

    def start(self, lan):
        import uvicorn

        host = "0.0.0.0" if lan else "127.0.0.1"
        config = uvicorn.Config(self.application, host=host, port=self.port, log_config=None, access_log=False)
        self.server = uvicorn.Server(config)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        for _ in range(100):
            if healthy(self.port, 0.3):
                return True
            if not self.thread.is_alive():
                return False
            time.sleep(0.1)
        return False

    def stop(self):
        if self.server:
            self.server.should_exit = True
        if self.thread:
            self.thread.join(timeout=10)


# ---------- 위젯 ----------
class Widget:
    def __init__(self):
        self.proc = None

    def start(self):
        if not WIDGET_PS1.is_file():
            log.warning("위젯 파일 없음: %s", WIDGET_PS1)
            return
        if self.proc and self.proc.poll() is None:
            return
        # 이미 떠 있으면 widget.ps1 이 뮤텍스를 보고 바로 끝난다
        self.proc = subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-STA", "-WindowStyle", "Hidden",
             "-ExecutionPolicy", "Bypass", "-File", str(WIDGET_PS1)],
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# ---------- 가져오기 ----------
def import_from(url):
    """다른 서버의 할 일을 id 그대로 복사 (이미 있는 id 는 건너뜀)."""
    sys.path.insert(0, str(BASE / "api"))
    from app.db import SQLiteDB

    with urllib.request.urlopen(url.rstrip("/") + "/todos", timeout=10) as r:
        items = json.loads(r.read().decode("utf-8"))
    db = SQLiteDB(str(DB_PATH))
    db.open()
    added = 0
    for t in items:
        _, n = db.run(
            "INSERT OR IGNORE INTO todos (id, text, done, priority, start, due, color, created_at, updated_at) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            (t["id"], t["text"], 1 if t["done"] else 0, t["priority"], t.get("start"), t.get("due"),
             t.get("color"), t["created_at"], t["updated_at"]),
        )
        added += n
    db.close()
    return len(items), added


# ---------- 트레이 ----------
def run_tray(server, widget, settings):
    import pystray
    from PIL import Image

    port = server.port

    def phone_url(_=None):
        ip = lan_ip()
        return f"휴대폰 주소: http://{ip}:{port}" if ip else "휴대폰 주소: 네트워크 없음"

    def on_open(icon, item):
        open_window(port)

    def on_widget(icon, item):
        widget.start()

    def on_lan(icon, item):
        settings["lan"] = not settings["lan"]
        save_settings(settings)
        server.stop()
        if not server.start(settings["lan"]):
            message("서버를 다시 시작하지 못했어요. 프로그램을 다시 실행해 주세요.", error=True)
        icon.update_menu()

    def on_data(icon, item):
        os.startfile(str(DATA_DIR))

    def on_quit(icon, item):
        icon.stop()

    menu = pystray.Menu(
        pystray.MenuItem("열기", on_open, default=True),
        pystray.MenuItem("달력 위젯 켜기", on_widget),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("휴대폰 접속 허용 (같은 와이파이)", on_lan, checked=lambda _: settings["lan"]),
        pystray.MenuItem(phone_url, None, enabled=False, visible=lambda _: settings["lan"]),
        pystray.MenuItem("데이터 폴더 열기", on_data),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("종료", on_quit),
    )
    image = Image.open(ICON_PNG) if ICON_PNG.is_file() else Image.new("RGB", (64, 64), "#2b4bb8")
    pystray.Icon("TodoNote", image, APP_TITLE, menu).run()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--background", action="store_true")
    p.add_argument("--no-tray", action="store_true")
    p.add_argument("--port", type=int)
    p.add_argument("--import-from")
    args = p.parse_args()

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(DATA_DIR / "desktop.log"), level=logging.INFO, encoding="utf-8",
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if sys.stdout is None:  # 창 없는 exe: uvicorn 등이 print 해도 죽지 않게
        sys.stdout = sys.stderr = open(DATA_DIR / "desktop.log", "a", encoding="utf-8")

    if args.import_from:
        try:
            total, added = import_from(args.import_from)
            message(f"{total}개 중 {added}개를 가져왔어요.\n(이미 있던 {total - added}개는 건너뜀)")
        except Exception as e:  # noqa: BLE001 — 사용자에게 그대로 보여줌
            message(f"가져오지 못했어요: {e}", error=True)
        return

    settings = load_settings()
    port = args.port or int(settings["port"])

    if not args.no_tray and not single_instance():
        open_window(port)  # 이미 실행 중 → 창만 열기
        return
    if not port_free(port):
        if healthy(port):
            message(f"{port} 포트에서 다른 할 일 노트 서버(예: Docker 판)가 이미 실행 중이에요.\n"
                    "그쪽을 끄거나 설정 파일에서 port 를 바꿔 주세요.\n\n" + str(SETTINGS_PATH), error=True)
        else:
            message(f"{port} 포트를 다른 프로그램이 쓰고 있어요.\n설정 파일에서 port 를 바꿔 주세요.\n\n"
                    + str(SETTINGS_PATH), error=True)
        save_settings(settings)
        return

    server = ServerThread(build_app(), port)
    if not server.start(settings["lan"] and not args.no_tray):
        message("서버를 시작하지 못했어요. 로그를 확인해 주세요.\n\n" + str(DATA_DIR / "desktop.log"), error=True)
        return
    log.info("started on port %s (db=%s)", port, DB_PATH)

    if args.no_tray:
        print(f"http://127.0.0.1:{port}  (db: {DB_PATH})  Ctrl+C 로 종료", flush=True)
        try:
            while server.thread.is_alive():
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
        server.stop()
        return

    widget = Widget()
    if settings["widget"]:
        widget.start()
    if not args.background:
        open_window(port)
    try:
        run_tray(server, widget, settings)
    finally:
        widget.stop()
        server.stop()


if __name__ == "__main__":
    main()
