#!/usr/bin/env python3
"""色の詳細補正の画面のなんちゃってモック(SVG)を作る。幅 300pt = 今の調整パネルの幅。
使い方: python3 scripts/mock_color.py <出力フォルダ>  (docs/color-grading-design.md を参照)"""
import colorsys, math, sys

OUT = sys.argv[1]
FONT = "Hiragino Sans, Hiragino Kaku Gothic ProN, sans-serif"
BG, CARD, LINE = "#1e1e20", "#2a2a2d", "#3a3a3e"
TEXT, TEXT2, TEXT3 = "#ececee", "#a8a8ae", "#6e6e74"
ACCENT = "#0a84ff"
W = 300

def hsl(h, s=0.85, l=0.55):
    r, g, b = colorsys.hls_to_rgb((h % 360) / 360, l, s)
    return "#%02x%02x%02x" % (int(r * 255), int(g * 255), int(b * 255))

def text(x, y, s, size=12, color=TEXT, weight=400, anchor="start", mono=False):
    fam = "SF Mono, Menlo, monospace" if mono else FONT
    return (f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" fill="{color}" '
            f'font-weight="{weight}" text-anchor="{anchor}">{s}</text>')

def header(y, title):
    # InspectorSection の見出し(シェブロン + 太字)
    return (f'<path d="M14 {y-8} l4 4 l-4 4" stroke="{TEXT2}" stroke-width="1.6" fill="none" '
            f'transform="rotate(90 16 {y-4})"/>' + text(26, y, title, 13, TEXT, 600))

def slider(y, title, value, pos, track=None, neutral=0.5, edited=True, highlight=False):
    """AdjustSlider と同じ並び: 見出し / 値(等幅)/ ↶、下にスライダー。track はグラデーションの id"""
    out = []
    if highlight:
        out.append(f'<rect x="10" y="{y-14}" width="{W-20}" height="38" rx="6" fill="{ACCENT}" fill-opacity="0.16"/>')
    out.append(text(16, y, title, 12))
    out.append(text(W - 40, y, value, 12, TEXT if edited else TEXT2, anchor="end", mono=True))
    out.append(text(W - 16, y, "↶", 12, TEXT2 if edited else TEXT3, anchor="end"))
    ty = y + 12
    fill = f'url(#{track})' if track else LINE
    out.append(f'<rect x="16" y="{ty-2}" width="{W-32}" height="4" rx="2" fill="{fill}"/>')
    if not track:
        # 中立点から値までを青で塗る(macOS の標準スライダーの見た目に寄せる)
        x0, x1 = 16 + (W - 32) * min(neutral, pos), 16 + (W - 32) * max(neutral, pos)
        out.append(f'<rect x="{x0}" y="{ty-2}" width="{x1-x0}" height="4" rx="2" fill="{ACCENT}"/>')
    kx = 16 + (W - 32) * pos
    out.append(f'<circle cx="{kx}" cy="{ty}" r="7" fill="#f2f2f4" stroke="#00000055" stroke-width="0.5"/>')
    return "".join(out)

def button(x, y, w, label, primary=False):
    fill = ACCENT if primary else "#3c3c40"
    return (f'<rect x="{x}" y="{y}" width="{w}" height="22" rx="5" fill="{fill}"/>'
            + text(x + w / 2, y + 15, label, 11, "#fff" if primary else TEXT, anchor="middle"))

def note(x, y, n):
    # 説明用の番号(モックの注記。実際の画面には出ない)
    return (f'<circle cx="{x}" cy="{y}" r="8" fill="#ff9f0a"/>' + text(x, y + 4, str(n), 10, "#000", 700, "middle"))

def frame(h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" viewBox="0 0 {W} {h}">'
            f'<title>{title}</title><rect width="{W}" height="{h}" fill="{BG}"/>{body}</svg>')

# ---------------------------------------------------------------- A: 色別補正
BANDS = [("赤", 0), ("オレンジ", 30), ("黄", 60), ("緑", 120), ("水色", 180), ("青", 225), ("紫", 270), ("マゼンタ", 315)]
SEL = 1  # オレンジを選んでいる
EDITED = {1, 5}  # 値を変えた色(下に点)

defs = ['<defs>']
# 色相のずらし: 選んだ色の前後(±30°)の色
c = BANDS[SEL][1]
defs.append('<linearGradient id="hueTrack">' + "".join(
    f'<stop offset="{k/10}" stop-color="{hsl(c - 30 + 6*k)}"/>' for k in range(11)) + '</linearGradient>')
defs.append(f'<linearGradient id="satTrack"><stop offset="0" stop-color="{hsl(c, 0.05, 0.5)}"/>'
            f'<stop offset="1" stop-color="{hsl(c, 1, 0.5)}"/></linearGradient>')
defs.append(f'<linearGradient id="lumTrack"><stop offset="0" stop-color="{hsl(c, 0.8, 0.12)}"/>'
            f'<stop offset="0.5" stop-color="{hsl(c, 0.8, 0.5)}"/><stop offset="1" stop-color="{hsl(c, 0.8, 0.9)}"/></linearGradient>')
# 色相の帯(0〜360°)
defs.append('<linearGradient id="hueBar">' + "".join(
    f'<stop offset="{k/12}" stop-color="{hsl(30*k)}"/>' for k in range(13)) + '</linearGradient>')
defs.append('</defs>')

b = ["".join(defs)]
y = 24
b.append(header(y, "色別補正"))
b.append(text(W - 16, y, "スポイト", 11, ACCENT, anchor="end"))
# スポイト(斜めの管と、上のゴム球)
b.append(f'<g transform="translate({W-72} {y-5}) rotate(45)">'
         f'<rect x="-2" y="-5" width="4" height="10" rx="1" fill="none" stroke="{ACCENT}" stroke-width="1.3"/>'
         f'<path d="M0 5 l0 3" stroke="{ACCENT}" stroke-width="1.3"/>'
         f'<rect x="-3.2" y="-9" width="6.4" height="4" rx="2" fill="{ACCENT}"/></g>')
b.append(note(W - 8, y - 16, 1))

# 色のチップ 8 個
y = 52
gap = (W - 32) / 8
for k, (name, h) in enumerate(BANDS):
    cx = 16 + gap * (k + 0.5)
    if k == SEL:
        b.append(f'<circle cx="{cx}" cy="{y}" r="13" fill="none" stroke="#fff" stroke-width="2"/>')
    b.append(f'<circle cx="{cx}" cy="{y}" r="10" fill="{hsl(h)}"/>')
    if k in EDITED:
        b.append(f'<circle cx="{cx}" cy="{y+19}" r="2.2" fill="{TEXT}"/>')
b.append(note(8, y - 14, 2))

# 色相の帯と、選んだ色の効く範囲(なだらかに弱まる)
y = 84
b.append(f'<rect x="16" y="{y}" width="{W-32}" height="8" rx="4" fill="url(#hueBar)"/>')
x0 = 16 + (W - 32) * (c - 30) / 360
x1 = 16 + (W - 32) * (c + 30) / 360
xc = 16 + (W - 32) * c / 360
b.append(f'<path d="M{x0} {y+16} Q{xc} {y-2} {x1} {y+16}" fill="none" stroke="#fff" stroke-width="1.2" stroke-opacity="0.9"/>')
b.append(f'<path d="M{xc} {y-3} l-4 -5 h8 z" fill="#fff"/>')
b.append(text(16, y + 30, "オレンジ", 12, TEXT, 600))
b.append(text(W - 16, y + 30, "効く範囲 ±30°", 11, TEXT2, anchor="end"))
b.append(note(W - 8, y + 4, 3))

y = 140
b.append(slider(y, "色相", "+12", 0.56, "hueTrack", highlight=False))
b.append(slider(y + 44, "彩度", "−20", 0.40, "satTrack"))
b.append(slider(y + 88, "輝度", "+8", 0.54, "lumTrack"))
b.append(note(8, y - 4, 4))

y = 284
b.append(f'<rect x="16" y="{y-11}" width="14" height="14" rx="3" fill="{ACCENT}"/>'
         f'<path d="M19 {y-4} l3 3 l6 -6" stroke="#fff" stroke-width="1.6" fill="none"/>')
b.append(text(36, y, "効く場所を表示(ドラッグ中だけ)", 12))
b.append(note(W - 8, y - 4, 5))

y = 304
b.append(button(16, y, 116, "この色をリセット"))
b.append(button(140, y, 144, "すべての色をリセット"))

# 全部の色を一覧で見る(折りたたみ)
y = 350
b.append(f'<line x1="16" y1="{y-14}" x2="{W-16}" y2="{y-14}" stroke="{LINE}"/>')
b.append(f'<path d="M16 {y-8} l4 4 l-4 4" stroke="{TEXT2}" stroke-width="1.6" fill="none" transform="rotate(90 18 {y-4})"/>')
b.append(text(28, y, "すべての色を一覧", 12, TEXT2))
b.append(note(W - 8, y - 4, 6))
y = 374
b.append(text(16, y, "", 10))
cols = ["色相", "彩度", "輝度"]
for j, col in enumerate(cols):
    b.append(text(150 + j * 50, y, col, 10, TEXT3, anchor="middle"))
vals = {1: ("+12", "−20", "+8"), 5: ("0", "+15", "−10")}
for k, (name, h) in enumerate(BANDS):
    ry = y + 18 + k * 19
    if k == SEL:
        b.append(f'<rect x="10" y="{ry-13}" width="{W-20}" height="18" rx="4" fill="{ACCENT}" fill-opacity="0.18"/>')
    b.append(f'<circle cx="22" cy="{ry-4}" r="5" fill="{hsl(h)}"/>')
    b.append(text(34, ry, name, 11, TEXT if k in vals else TEXT2))
    for j in range(3):
        v = vals.get(k, ("0", "0", "0"))[j]
        b.append(text(150 + j * 50, ry, v, 11, TEXT if v != "0" else TEXT3, anchor="middle", mono=True))
h_a = y + 18 + 8 * 19 + 6
open(f"{OUT}/color-hsl-mock.svg", "w").write(frame(h_a, "".join(b), "色別補正のモック"))

# ---------------------------------------------------------------- B: カラーグレーディング
b = []
y = 24
b.append(header(y, "カラーグレーディング"))
# 切り替え(シャドウ / 中間調 / ハイライト / 全体)。各ボタンに今の色の点
y = 40
segs = [("シャドウ", (200, 0.35)), ("中間調", (0, 0)), ("ハイライト", (38, 0.4)), ("全体", (0, 0))]
sw = (W - 32) / 4
b.append(f'<rect x="16" y="{y}" width="{W-32}" height="26" rx="6" fill="#3c3c40"/>')
for k, (label, (hh, ss)) in enumerate(segs):
    x = 16 + sw * k
    if k == 0:
        b.append(f'<rect x="{x+2}" y="{y+2}" width="{sw-4}" height="22" rx="5" fill="#636366"/>')
    b.append(text(x + sw / 2 + (5 if ss else 0), y + 17, label, 11, TEXT, anchor="middle"))
    if ss:
        b.append(f'<circle cx="{x + sw/2 - len(label)*5.5 - 2}" cy="{y+13}" r="3.5" fill="{hsl(hh, 0.9, 0.55)}"/>')
b.append(note(W - 8, y - 6, 1))

# 色相環(1 つだけ大きく)。外周に向かって彩度が上がる
cx, cy, R = W / 2, 172, 92
wheel = []
steps = 90
for k in range(steps):
    a0, a1 = 2 * math.pi * k / steps, 2 * math.pi * (k + 1) / steps
    for ring in range(6):
        r0, r1 = R * ring / 6, R * (ring + 1) / 6
        sat = (ring + 0.5) / 6
        col = hsl(math.degrees(a0), sat * 0.9, 0.5 + 0.08 * (1 - sat))
        p = (f"M{cx + r0*math.cos(a0):.2f} {cy - r0*math.sin(a0):.2f} "
             f"L{cx + r1*math.cos(a0):.2f} {cy - r1*math.sin(a0):.2f} "
             f"A{r1} {r1} 0 0 0 {cx + r1*math.cos(a1):.2f} {cy - r1*math.sin(a1):.2f} "
             f"L{cx + r0*math.cos(a1):.2f} {cy - r0*math.sin(a1):.2f} "
             + (f"A{r0} {r0} 0 0 1 {cx + r0*math.cos(a0):.2f} {cy - r0*math.sin(a0):.2f} " if r0 > 0 else "") + "Z")
        wheel.append(f'<path d="{p}" fill="{col}" stroke="{col}" stroke-width="0.6"/>')
b.append("".join(wheel))
b.append(f'<circle cx="{cx}" cy="{cy}" r="{R}" fill="none" stroke="#00000066"/>')
b.append(f'<line x1="{cx-6}" y1="{cy}" x2="{cx+6}" y2="{cy}" stroke="#ffffff88"/><line x1="{cx}" y1="{cy-6}" x2="{cx}" y2="{cy+6}" stroke="#ffffff88"/>')
# つまみ(シャドウ: 青緑寄り、彩度 35)
ang, sat = math.radians(200), 0.35
kx, ky = cx + R * sat * math.cos(ang), cy - R * sat * math.sin(ang)
b.append(f'<line x1="{cx}" y1="{cy}" x2="{kx}" y2="{ky}" stroke="#fff" stroke-opacity="0.6"/>')
b.append(f'<circle cx="{kx}" cy="{ky}" r="8" fill="{hsl(200, 0.9, 0.5)}" stroke="#fff" stroke-width="2"/>')
b.append(note(cx + R + 4, cy - R + 6, 2))

y = 286
b.append(text(16, y, "色相", 12, TEXT2) + text(52, y, "200°", 12, TEXT, mono=True))
b.append(text(150, y, "彩度", 12, TEXT2) + text(186, y, "35", 12, TEXT, mono=True))
b.append(text(W - 16, y, "↶", 12, TEXT2, anchor="end"))
b.append(note(W - 8, y - 18, 3))
y = 320
b.append(slider(y, "輝度", "−6", 0.47))
b.append(f'<line x1="16" y1="{y+36}" x2="{W-16}" y2="{y+36}" stroke="{LINE}"/>')
y = 380
b.append(slider(y, "ブレンド", "50", 0.5, neutral=0.5, edited=False))
b.append(slider(y + 44, "バランス", "+10", 0.55))
b.append(note(8, y - 4, 4))
h_b = y + 44 + 34
open(f"{OUT}/color-grading-mock.svg", "w").write(frame(h_b, "".join(b), "カラーグレーディングのモック"))
print("ok", h_a, h_b)
