#!/usr/bin/env python3
"""トーンカーブの画面のなんちゃってモック(SVG)を作る。幅 300pt = 今の調整パネルの幅。
使い方: python3 scripts/mock_curve.py <出力フォルダ>  (docs/tone-curve-design.md を参照)
部品(見出し・スライダー・切り替えなど)は scripts/mock_color.py と同じ形にしてある(同じアプリに見えるように)"""
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

def segmented(y, labels, sel):
    """2〜4 個の切り替え(macOS のセグメントに寄せる)"""
    sw = (W - 32) / len(labels)
    out = [f'<rect x="16" y="{y}" width="{W-32}" height="24" rx="6" fill="#3c3c40"/>']
    for k, label in enumerate(labels):
        x = 16 + sw * k
        if k == sel:
            out.append(f'<rect x="{x+2}" y="{y+2}" width="{sw-4}" height="20" rx="5" fill="#636366"/>')
        out.append(text(x + sw / 2, y + 16, label, 11, TEXT, anchor="middle"))
    return "".join(out)

def pipette(x, y, color=ACCENT, scale=1.0):
    """スポイト(斜めの管と、上のゴム球)"""
    return (f'<g transform="translate({x} {y}) rotate(45) scale({scale})">'
            f'<rect x="-2" y="-5" width="4" height="10" rx="1" fill="none" stroke="{color}" stroke-width="1.3"/>'
            f'<path d="M0 5 l0 3" stroke="{color}" stroke-width="1.3"/>'
            f'<rect x="-3.2" y="-9" width="6.4" height="4" rx="2" fill="{color}"/></g>')

def range_slider(y, title, value, lo, hi, track=None):
    """つまみが 2 つのスライダー(範囲を決める)"""
    out = [text(16, y, title, 12), text(W - 40, y, value, 12, TEXT, anchor="end", mono=True),
           text(W - 16, y, "↶", 12, TEXT2, anchor="end")]
    ty = y + 12
    out.append(f'<rect x="16" y="{ty-2}" width="{W-32}" height="4" rx="2" fill="{f"url(#{track})" if track else LINE}"/>')
    x0, x1 = 16 + (W - 32) * lo, 16 + (W - 32) * hi
    out.append(f'<rect x="{x0}" y="{ty-3}" width="{x1-x0}" height="6" rx="3" fill="none" stroke="{ACCENT}" stroke-width="1.5"/>')
    for kx in (x0, x1):
        out.append(f'<circle cx="{kx}" cy="{ty}" r="7" fill="#f2f2f4" stroke="#00000055" stroke-width="0.5"/>')
    return "".join(out)

def note(x, y, n):
    # 説明用の番号(モックの注記。実際の画面には出ない)
    return (f'<circle cx="{x}" cy="{y}" r="8" fill="#ff9f0a"/>' + text(x, y + 4, str(n), 10, "#000", 700, "middle"))

def frame(h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" viewBox="0 0 {W} {h}">'
            f'<title>{title}</title><rect width="{W}" height="{h}" fill="{BG}"/>{body}</svg>')


# 桜の写真(DSC01029)を Rawgenzo で現像した画像のヒストグラム(64 区間、いちばん高い区間を約 1)
HIST = {
    'R': [0.0, 0.0, 0.0, 0.001, 0.002, 0.003, 0.004, 0.005, 0.008, 0.009, 0.013, 0.018, 0.023, 0.023, 0.03, 0.043, 0.055, 0.075, 0.093, 0.114, 0.126, 0.151, 0.153, 0.184, 0.228, 0.311, 0.36, 0.425, 0.486, 0.673, 0.972, 1.0, 0.901, 0.983, 0.767, 0.407, 0.268, 0.211, 0.161, 0.132, 0.116, 0.11, 0.107, 0.083, 0.083, 0.067, 0.053, 0.047, 0.043, 0.038, 0.029, 0.026, 0.028, 0.023, 0.015, 0.013, 0.012, 0.011, 0.009, 0.008, 0.004, 0.003, 0.001, 0.003],
    'G': [0.002, 0.004, 0.005, 0.008, 0.009, 0.01, 0.012, 0.014, 0.02, 0.024, 0.026, 0.028, 0.029, 0.037, 0.048, 0.062, 0.072, 0.084, 0.093, 0.12, 0.154, 0.158, 0.154, 0.16, 0.176, 0.192, 0.213, 0.239, 0.273, 0.31, 0.384, 0.448, 0.524, 0.634, 0.774, 0.835, 0.765, 0.872, 0.812, 0.573, 0.323, 0.177, 0.096, 0.063, 0.05, 0.04, 0.039, 0.034, 0.028, 0.025, 0.018, 0.018, 0.018, 0.011, 0.01, 0.009, 0.009, 0.008, 0.007, 0.005, 0.002, 0.001, 0.001, 0.0],
    'B': [0.015, 0.014, 0.015, 0.02, 0.022, 0.026, 0.028, 0.029, 0.028, 0.03, 0.03, 0.034, 0.033, 0.034, 0.037, 0.042, 0.049, 0.051, 0.057, 0.065, 0.07, 0.074, 0.077, 0.087, 0.095, 0.108, 0.125, 0.122, 0.126, 0.121, 0.121, 0.13, 0.145, 0.157, 0.174, 0.191, 0.23, 0.238, 0.261, 0.315, 0.368, 0.417, 0.458, 0.529, 0.611, 0.647, 0.632, 0.655, 0.728, 0.664, 0.483, 0.274, 0.132, 0.043, 0.016, 0.013, 0.01, 0.011, 0.01, 0.008, 0.007, 0.004, 0.002, 0.001],
    'L': [0.0, 0.003, 0.004, 0.005, 0.008, 0.009, 0.01, 0.012, 0.018, 0.022, 0.025, 0.027, 0.029, 0.033, 0.045, 0.058, 0.068, 0.08, 0.09, 0.108, 0.137, 0.158, 0.151, 0.154, 0.162, 0.187, 0.217, 0.238, 0.276, 0.314, 0.386, 0.463, 0.535, 0.677, 0.841, 0.855, 0.793, 0.891, 0.824, 0.492, 0.26, 0.155, 0.098, 0.064, 0.055, 0.046, 0.039, 0.037, 0.03, 0.027, 0.022, 0.02, 0.021, 0.012, 0.011, 0.01, 0.009, 0.009, 0.007, 0.007, 0.003, 0.001, 0.001, 0.0],
}

GX, GW = 16, W - 32          # グラフの左端と幅(正方形)

def smooth(points, n=120):
    """点を通る単調なカーブ(Fritsch–Carlson の 3 次エルミート)。カーブが行き過ぎて山や谷を作らない"""
    xs = [p[0] for p in points]; ys = [p[1] for p in points]
    k = len(points)
    d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(k - 1)]
    m = [d[0]] + [0 if d[i - 1] * d[i] <= 0 else (d[i - 1] + d[i]) / 2 for i in range(1, k - 1)] + [d[-1]]
    for i in range(k - 1):
        if d[i] == 0: m[i] = m[i + 1] = 0
    out = []
    for j in range(n + 1):
        x = j / n
        i = min(max(sum(1 for xx in xs if xx <= x) - 1, 0), k - 2)
        h = xs[i + 1] - xs[i]; t = (x - xs[i]) / h
        h00 = 2*t**3 - 3*t**2 + 1; h10 = t**3 - 2*t**2 + t; h01 = -2*t**3 + 3*t**2; h11 = t**3 - t**2
        out.append((x, h00*ys[i] + h10*h*m[i] + h01*ys[i+1] + h11*h*m[i+1]))
    return out

def graph(y0, hist, hist_color, curves, points, selected, axis=None):
    """カーブのグラフ。curves = [(点の並び, 色, 太さ, 透明度)]。axis は R・G・B のときの軸のグラデーションの id"""
    s = GW
    def X(v): return GX + v * s
    def Y(v): return y0 + (1 - v) * s
    out = [f'<rect x="{GX}" y="{y0}" width="{s}" height="{s}" rx="6" fill="#141416" stroke="{LINE}"/>']
    # ヒストグラム(後ろに薄く)
    n = len(hist)
    path = f"M{X(0)} {Y(0)} " + " ".join(f"L{X(i/(n-1)):.1f} {Y(min(v, 1) * 0.9):.1f}" for i, v in enumerate(hist)) + f" L{X(1)} {Y(0)} Z"
    out.append(f'<path d="{path}" fill="{hist_color}" fill-opacity="0.28"/>')
    for q in (0.25, 0.5, 0.75):
        out.append(f'<line x1="{X(q)}" y1="{y0}" x2="{X(q)}" y2="{y0+s}" stroke="#ffffff" stroke-opacity="0.08"/>')
        out.append(f'<line x1="{GX}" y1="{Y(q)}" x2="{GX+s}" y2="{Y(q)}" stroke="#ffffff" stroke-opacity="0.08"/>')
    out.append(f'<line x1="{X(0)}" y1="{Y(0)}" x2="{X(1)}" y2="{Y(1)}" stroke="#ffffff" stroke-opacity="0.25" stroke-dasharray="3 3"/>')
    if axis:
        out.append(f'<rect x="{GX}" y="{y0+s+4}" width="{s}" height="5" rx="2" fill="url(#{axis}X)"/>')
        out.append(f'<rect x="{GX-9}" y="{y0}" width="5" height="{s}" rx="2" fill="url(#{axis}Y)"/>')
    for pts, color, width, op in curves:
        c = smooth(pts)
        out.append(f'<path d="M' + " L".join(f"{X(x):.1f} {Y(min(max(v,0),1)):.1f}" for x, v in c) + f'" fill="none" stroke="{color}" stroke-width="{width}" stroke-opacity="{op}"/>')
    for i, (px, py) in enumerate(points):
        if i == selected:
            out.append(f'<circle cx="{X(px)}" cy="{Y(py)}" r="7" fill="none" stroke="#fff" stroke-width="1.5"/>')
        out.append(f'<circle cx="{X(px)}" cy="{Y(py)}" r="4" fill="#fff" stroke="#000" stroke-opacity="0.5"/>')
    return "".join(out)

def segmented_dots(y, labels, sel):
    """チャンネルの切り替え(R・G・B には色の点)"""
    sw = (W - 32) / len(labels)
    out = [f'<rect x="16" y="{y}" width="{W-32}" height="24" rx="6" fill="#3c3c40"/>']
    for k, (label, dot) in enumerate(labels):
        x = 16 + sw * k
        if k == sel:
            out.append(f'<rect x="{x+2}" y="{y+2}" width="{sw-4}" height="20" rx="5" fill="#636366"/>')
        if dot:
            out.append(f'<circle cx="{x + sw/2 - 8}" cy="{y+12}" r="4" fill="{dot}"/>')
            out.append(text(x + sw / 2 + 4, y + 16, label, 11, TEXT, anchor="middle"))
        else:
            out.append(text(x + sw / 2, y + 16, label, 11, TEXT, anchor="middle"))
    return "".join(out)

def toolbar(y, preset):
    out = [f'<rect x="16" y="{y}" width="168" height="24" rx="5" fill="#3c3c40"/>',
           text(26, y + 16, preset, 11, TEXT), text(176, y + 16, "▾", 10, TEXT2, anchor="end")]
    # 写真の上でドラッグして直す道具(丸に上下の矢印)
    cx = 206
    out.append(f'<circle cx="{cx}" cy="{y+12}" r="9" fill="none" stroke="{ACCENT}" stroke-width="1.4"/>')
    out.append(f'<path d="M{cx} {y+5} l-3 4 h6 z M{cx} {y+19} l-3 -4 h6 z" fill="{ACCENT}"/>')
    out.append(text(W - 16, y + 16, "↶", 13, TEXT2, anchor="end"))
    return "".join(out)

LABELS = [("輝度", None), ("R", "#ff5555"), ("G", "#55dd66"), ("B", "#5588ff")]

# ---------------------------------------------------------------- A: 輝度
LUMA_POINTS = [(0, 0), (0.22, 0.16), (0.62, 0.70), (1, 1)]
b = ['<defs></defs>']
y = 24
b.append(header(y, "トーンカーブ"))
b.append(segmented_dots(36, LABELS, 0))
b.append(note(W - 8, 30, 1))
b.append(toolbar(70, "中くらいのコントラスト"))
b.append(note(8, 82, 2))
b.append(graph(106, HIST["L"], "#d0d0d8", [(LUMA_POINTS, "#ffffff", 2, 0.95)], LUMA_POINTS, 2))
b.append(note(W - 8, 112, 3))
y = 106 + GW + 26
b.append(text(16, y, "入力", 11, TEXT2) + f'<rect x="46" y="{y-15}" width="52" height="22" rx="4" fill="#2c2c30" stroke="{LINE}"/>' + text(72, y, "158", 12, TEXT, anchor="middle", mono=True))
b.append(text(112, y, "出力", 11, TEXT2) + f'<rect x="142" y="{y-15}" width="52" height="22" rx="4" fill="#2c2c30" stroke="{LINE}"/>' + text(168, y, "179", 12, TEXT, anchor="middle", mono=True))
b.append(text(W - 16, y, "3 / 16 点", 11, TEXT3, anchor="end"))
b.append(note(8, y - 4, 4))
y += 40
b.append(slider(y, "彩度の連動", "0", 0.0, neutral=0.0, edited=False))
b.append(note(8, y - 4, 5))
y += 36
b.append(text(16, y, "クリックで点を足す・カーブの外へドラッグで消す", 10, TEXT3))
y += 24
b.append(f'<rect x="16" y="{y-14}" width="{W-32}" height="26" rx="6" fill="none" stroke="{LINE}" stroke-dasharray="4 3"/>')
b.append(text(28, y + 3, "› スライダーで調整(後回し)", 11, TEXT3))
b.append(note(W - 8, y - 2, 6))
h_a = y + 28
open(f"{OUT}/tone-curve-luma-mock.svg", "w").write(frame(h_a, "".join(b), "トーンカーブ(輝度)のモック"))

# ---------------------------------------------------------------- B: R のチャンネル
RED_POINTS = [(0, 0.04), (0.5, 0.53), (1, 1)]
b = ['<defs>'
     '<linearGradient id="redX"><stop offset="0" stop-color="#00c8c8"/><stop offset="1" stop-color="#ff4040"/></linearGradient>'
     '<linearGradient id="redY" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#00c8c8"/><stop offset="1" stop-color="#ff4040"/></linearGradient>'
     '</defs>']
y = 24
b.append(header(y, "トーンカーブ"))
b.append(segmented_dots(36, LABELS, 1))
b.append(toolbar(70, "カスタム"))
b.append(graph(106, HIST["R"], "#ff6060",
               [(LUMA_POINTS, "#ffffff", 1.2, 0.3), (RED_POINTS, "#ff5555", 2, 0.95)], RED_POINTS, 0, axis="red"))
b.append(note(W - 8, 112, 7))
y = 106 + GW + 30
b.append(text(16, y, "入力", 11, TEXT2) + f'<rect x="46" y="{y-15}" width="52" height="22" rx="4" fill="#2c2c30" stroke="{LINE}"/>' + text(72, y, "0", 12, TEXT, anchor="middle", mono=True))
b.append(text(112, y, "出力", 11, TEXT2) + f'<rect x="142" y="{y-15}" width="52" height="22" rx="4" fill="#2c2c30" stroke="{LINE}"/>' + text(168, y, "10", 12, TEXT, anchor="middle", mono=True))
y += 34
b.append(text(16, y, "R のカーブは色を直接変える。", 10, TEXT3))
b.append(text(16, y + 16, "上げると赤み、下げるとシアン寄り。白線は輝度", 10, TEXT3))
y += 40
b.append(button(16, y, 140, "このチャンネルを戻す"))
b.append(button(164, y, 120, "全部を戻す"))
h_b = y + 34
open(f"{OUT}/tone-curve-rgb-mock.svg", "w").write(frame(h_b, "".join(b), "トーンカーブ(R のチャンネル)のモック"))
print("ok", h_a, h_b)
