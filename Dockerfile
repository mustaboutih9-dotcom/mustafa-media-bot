# syntax=docker/dockerfile:1
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir requests yt-dlp gallery-dl
COPY <<'PY' /app/bot.py
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit

import requests

TOKEN = os.environ["BOT_TOKEN"].strip()
PAIR = os.environ["PAIR_CODE"].strip()
if len(PAIR) < 12:
    raise SystemExit("Set PAIR_CODE to at least 12 characters.")

HOSTS = {
    "instagram.com", "www.instagram.com",
    "tiktok.com", "www.tiktok.com", "m.tiktok.com",
    "vm.tiktok.com", "vt.tiktok.com",
    "facebook.com", "www.facebook.com", "m.facebook.com", "fb.watch",
}
MEDIA = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".mp4", ".webm", ".mov"}


def telegram(method, data=None, files=None):
    response = requests.post(
        f"https://api.telegram.org/bot{TOKEN}/{method}",
        data=data, files=files, timeout=(10, 90 if files else 40),
    )
    body = response.json()
    if not body.get("ok"):
        raise RuntimeError(f"Telegram API error {body.get('error_code')}")
    return body["result"]


def say(chat, text):
    telegram("sendMessage", {"chat_id": chat, "text": text})


def post_url(text):
    if len(text) > 2000 or not re.fullmatch(r"https://\S+", text):
        return None
    try:
        url = urlsplit(text)
        if url.netloc.lower() not in HOSTS:
            return None
    except ValueError:
        return None
    site, path = url.hostname, url.path
    if site.endswith("instagram.com"):
        valid = re.fullmatch(r"/(?:p|reel|reels|tv)/[\w-]+/?", path)
    elif site in {"vm.tiktok.com", "vt.tiktok.com", "fb.watch"}:
        valid = re.fullmatch(r"/[\w-]+/?", path)
    elif site.endswith("tiktok.com"):
        valid = re.fullmatch(r"/(?:@[\w.-]+/(?:video|photo)/\d+|t/[\w-]+)/?", path)
    else:
        valid = re.search(
            r"(?:^/(?:watch|share|reel)(?:/|$)|/(?:posts|videos)/|^/(?:photo|permalink|story)\.php$)",
            path,
        )
    return url._replace(fragment="").geturl() if valid else None


def download(url, folder):
    video = [
        "yt_dlp", "--ignore-config", "--no-playlist", "--socket-timeout", "15",
        "--retries", "1", "--max-filesize", "49M", "-f", "b[ext=mp4]/b",
        "-o", str(folder / "%(id)s.%(ext)s"), "--", url,
    ]
    gallery = ["gallery_dl", "--config-ignore", "--range", "1-10",
               "-D", str(folder), "--", url]
    path = urlsplit(url).path
    for command in ([gallery, video] if path.startswith("/p/") or "/photo/" in path
                    else [video, gallery]):
        try:
            subprocess.run([sys.executable, "-m", *command], timeout=75,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            continue
        files = [
            f for f in sorted(folder.rglob("*"))
            if f.is_file() and f.suffix.lower() in MEDIA
            and 0 < f.stat().st_size <= 49_000_000
        ]
        if files:
            return files[:10]
    return []


owner = int(os.environ.get("OWNER_ID") or "0")
offset = 0
print("Bot started.", flush=True)

while True:
    try:
        updates = telegram("getUpdates", {
            "offset": offset, "timeout": 25, "allowed_updates": '["message"]',
        })
        for update in updates:
            offset = update["update_id"] + 1
            msg = update.get("message", {})
            chat = msg.get("chat", {})
            sender = msg.get("from", {}).get("id")
            text = msg.get("text", "").strip()
            if chat.get("type") != "private" or not sender:
                continue
            if not owner and secrets.compare_digest(
                text.encode(), ("/connect " + PAIR).encode()
            ):
                owner = sender
                say(chat["id"], f"ربطت البوت. ابعث رابط عمومي.\nرقم حسابك: {owner}")
                continue
            if sender != owner:
                continue
            url = post_url(text)
            if not url:
                say(chat["id"], "ابعث رابط منشور عمومي من TikTok أو Instagram أو Facebook.")
                continue
            with TemporaryDirectory() as folder:
                say(chat["id"], "راني نحاول نحمّل المنشور…")
                files = download(url, Path(folder))
                if not files:
                    say(chat["id"], "ما قدرتش نحمّل هاد الرابط. جرّب منشور عمومي آخر.")
                for file in files:
                    with file.open("rb") as data:
                        telegram("sendDocument", {"chat_id": chat["id"]},
                                 {"document": (file.name, data)})
    except (requests.RequestException, RuntimeError, ValueError):
        print("Telegram request failed; retrying.", flush=True)
        time.sleep(4)
PY
CMD ["python", "-u", "/app/bot.py"]
