"""web/public/icon.svg 와 같은 그림을 Pillow 로 그려 PNG/ICO 아이콘을 만든다.

    python desktop/make_icons.py
  → web/public/icon-192.png, icon-512.png, apple-touch-icon.png (설치형 웹앱·휴대폰 홈 화면)
  → desktop/build/icon.png, icon.ico (exe·트레이·설치 파일)
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BLUE = (0x2B, 0x4B, 0xB8, 255)
SS = 4  # 4배로 그린 뒤 줄여서 가장자리를 부드럽게


def draw(size, full_bleed=False):
    """full_bleed: 모서리를 둥글리지 않음 (iOS 가 직접 둥글림)."""
    n = 512 * SS
    k = SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if full_bleed:
        d.rectangle((0, 0, n, n), fill=BLUE)
    else:
        d.rounded_rectangle((0, 0, n - 1, n - 1), radius=112 * k, fill=BLUE)

    def white(alpha):
        return (255, 255, 255, round(255 * alpha))

    def bar(x, y, w, h, r, alpha):
        layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(layer).rounded_rectangle(
            (x * k, y * k, (x + w) * k, (y + h) * k), radius=r * k, fill=white(alpha))
        img.alpha_composite(layer)

    for y in (136, 232, 328):
        bar(128, y, 64, 64, 14, 1)
    bar(232, 152, 160, 32, 16, 0.85)
    bar(232, 248, 160, 32, 16, 0.55)
    bar(232, 344, 120, 32, 16, 0.85)
    d = ImageDraw.Draw(img)
    pts = [(142 * k, 264 * k), (158 * k, 280 * k), (186 * k, 248 * k)]
    d.line(pts, fill=BLUE, width=12 * k, joint="curve")
    for x, y in pts[::2]:
        r = 6 * k
        d.ellipse((x - r, y - r, x + r, y + r), fill=BLUE)
    return img.resize((size, size), Image.LANCZOS)


def main():
    pub = ROOT / "web" / "public"
    build = ROOT / "desktop" / "build"
    build.mkdir(parents=True, exist_ok=True)
    draw(192).save(pub / "icon-192.png", optimize=True)
    draw(512).save(pub / "icon-512.png", optimize=True)
    draw(180, full_bleed=True).convert("RGB").save(pub / "apple-touch-icon.png", optimize=True)
    big = draw(256)
    big.save(build / "icon.png")
    big.save(build / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons ->", pub, build)


if __name__ == "__main__":
    main()
