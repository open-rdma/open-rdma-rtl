#!/usr/bin/env python3
"""生成入口页用的接口全景图缩略图。

用无头浏览器渲染 ports.html，自动定位页面中最后一张卡片（RX 全景条），
裁出内容包围盒后缩放进 16:10 卡片画布。依赖 google-chrome 与 Pillow；
任一缺失时跳过并返回 0，因为缩略图只是入口页装饰，不影响 ports.html。

用法: preview.py [ports.html] [ports.preview.png]
"""
import pathlib, shutil, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
HTML = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / 'ports.html'
OUT = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else HERE.parent / 'ports.preview.png'

WINDOW = (3950, 2400)   # 足够容纳整页，避免出现滚动条
STRIP_W = 1540          # 缩略图内图形目标宽度
CARD = (1600, 1000)     # 缩略图画布
PANEL = (7, 27, 43)     # 卡片面板底色
TOL = 18                # 判定"非背景"的颜色容差
MIN_BAND = 60           # 忽略低于此高度的内容带

chrome = shutil.which('google-chrome') or shutil.which('chromium') or shutil.which('chromium-browser')
if not chrome:
    print('preview: chrome not found, skipped'); sys.exit(0)
try:
    from PIL import Image
except ImportError:
    print('preview: Pillow not installed, skipped'); sys.exit(0)
if not HTML.exists():
    print(f'preview: {HTML} missing, skipped'); sys.exit(0)

with tempfile.TemporaryDirectory() as td:
    shot = pathlib.Path(td) / 'page.png'
    subprocess.run([chrome, '--headless=new', '--disable-gpu', '--no-sandbox',
                    '--hide-scrollbars', f'--window-size={WINDOW[0]},{WINDOW[1]}',
                    f'--screenshot={shot}', f'file://{HTML}'],
                   check=False, capture_output=True)
    if not shot.exists():
        print('preview: screenshot failed, skipped'); sys.exit(0)

    page = Image.open(shot).convert('RGB')
    W, H = page.size
    bg = page.getpixel((5, 5))
    px = page.load()

    def differs(p):
        return abs(p[0]-bg[0]) + abs(p[1]-bg[1]) + abs(p[2]-bg[2]) > TOL

    # 纵向内容分带，取最后一条即 RX 卡片
    bands, start = [], None
    for y in range(0, H, 4):
        ink = sum(1 for x in range(0, W, 8) if differs(px[x, y]))
        on = ink > 3
        if on and start is None:
            start = y
        elif not on and start is not None:
            if y - start >= MIN_BAND:
                bands.append((start, y))
            start = None
    if start is not None and H - start >= MIN_BAND:
        bands.append((start, H))
    if not bands:
        print('preview: no content band found, skipped'); sys.exit(0)

    top, bottom = bands[-1]
    strip = page.crop((0, top, W, bottom))

    # 横向再收紧到内容包围盒
    sw, sh = strip.size
    sx, ex = 0, sw
    for x in range(0, sw, 4):
        if any(differs(strip.getpixel((x, y))) for y in range(0, sh, 6)):
            sx = x; break
    for x in range(sw - 1, 0, -4):
        if any(differs(strip.getpixel((x, y))) for y in range(0, sh, 6)):
            ex = x + 1; break
    strip = strip.crop((max(0, sx - 6), 0, min(sw, ex + 6), sh))

    w = STRIP_W
    h = max(1, int(strip.height * w / strip.width))
    if h > CARD[1] - 40:
        h = CARD[1] - 40
        w = max(1, int(strip.width * h / strip.height))
    strip = strip.resize((w, h), Image.LANCZOS)

    canvas = Image.new('RGB', CARD, PANEL)
    canvas.paste(strip, ((CARD[0] - w) // 2, (CARD[1] - h) // 2))
    canvas.save(OUT)

print(f'preview: band {bands[-1]} -> wrote {OUT} ({OUT.stat().st_size} bytes)')
