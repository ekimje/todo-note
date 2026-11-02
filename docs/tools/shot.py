import sys
from playwright.sync_api import sync_playwright
url, out = sys.argv[1], sys.argv[2]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1100, "height": 760}, locale="ko-KR")
    pg.goto(url, wait_until="networkidle"); pg.wait_for_timeout(800)
    pg.screenshot(path=out, full_page=True); b.close()
