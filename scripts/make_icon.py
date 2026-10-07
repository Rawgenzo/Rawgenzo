import numpy as np
from PIL import Image, ImageFilter

S = 2048                      # 2倍で描いて縮小(アンチエイリアス)
k = S / 1024
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) + 0.5

def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)

def mix(a, b, t):
    t = t[..., None] if np.ndim(t) == 2 else t
    return a + (b - a) * t

# ---- squircle (macOS 824pt グリッド) ----
cx = cy = S / 2
half = 412 * k
n = 5.0
sq = (np.abs((xx - cx) / half) ** n + np.abs((yy - cy) / half) ** n)
body = 1 - smooth(1 - 0.004, 1 + 0.004, sq)        # 内側=1

# 背景: グラファイトの縦グラデーション + 上部のかすかな光
t = (yy - (cy - half)) / (2 * half)
top = np.array([0.20, 0.215, 0.255]); bot = np.array([0.045, 0.05, 0.065])
bg = mix(top, bot, np.clip(t, 0, 1) ** 0.8)
glow = np.exp(-(((xx - cx) / (half * 0.9)) ** 2 + ((yy - (cy - half * 0.9)) / (half * 0.55)) ** 2))
bg = bg + glow[..., None] * np.array([0.06, 0.07, 0.09])

# ---- レンズ内の「景色」: 夕焼けの空・太陽・山並み ----
R_glass = 262 * k
lx, ly = cx, cy
u = (xx - lx) / R_glass      # -1..1
v = (yy - ly) / R_glass
sky_t = np.clip((v + 1) / 1.45, 0, 1)
c_top = np.array([0.10, 0.16, 0.48]); c_mid = np.array([0.62, 0.22, 0.52]); c_low = np.array([1.00, 0.56, 0.20])
sky = np.where(sky_t[..., None] < 0.55,
               mix(c_top, c_mid, smooth(0, 0.55, sky_t)),
               mix(c_mid, c_low, smooth(0.55, 1.0, sky_t)))
sun_d = np.hypot(u - 0.18, v - 0.22)
sun = 1 - smooth(0.20, 0.215, sun_d)
halo = np.exp(-(sun_d / 0.45) ** 2) * 0.55
scene = sky + halo[..., None] * np.array([1.0, 0.62, 0.30])
scene = mix(scene, np.array([1.0, 0.93, 0.78]), sun)
ridge1 = 0.42 + 0.10 * np.sin(u * 3.1 + 0.6) + 0.05 * np.sin(u * 7.3)
ridge2 = 0.62 + 0.06 * np.sin(u * 4.2 - 1.2) + 0.03 * np.sin(u * 11.0)
m1 = smooth(-0.004, 0.004, v - ridge1); m2 = smooth(-0.004, 0.004, v - ridge2)
scene = mix(scene, np.array([0.22, 0.10, 0.22]), m1)
scene = mix(scene, np.array([0.07, 0.04, 0.10]), m2)
scene = np.clip(scene, 0, 1)

# ---- ベイヤー配列(RGGB): 景色を実際にサンプリングしたモザイク ----
T = 30 * k
ix = np.floor((xx - lx) / T); iy = np.floor((yy - ly) / T)
tcx = (ix + 0.5) * T + lx; tcy = (iy + 0.5) * T + ly
# タイル中心の景色を取る
sx = np.clip(tcx.astype(int), 0, S - 1); sy = np.clip(tcy.astype(int), 0, S - 1)
sample = scene[sy, sx]
evx = (ix % 2 == 0); evy = (iy % 2 == 0)
is_r = evx & evy; is_b = (~evx) & (~evy); is_g = ~(is_r | is_b)
val = np.where(is_r, sample[..., 0], np.where(is_b, sample[..., 2], sample[..., 1]))
val = 0.18 + 0.95 * val
chan = np.zeros_like(scene)
chan[is_r] = [1.0, 0.16, 0.20]; chan[is_g] = [0.20, 0.95, 0.40]; chan[is_b] = [0.22, 0.42, 1.0]
mosaic = chan * val[..., None]
# タイルの溝
fx = ((xx - lx) / T) % 1; fy = ((yy - ly) / T) % 1
gap = 0.07
tile_mask = smooth(gap, gap + 0.03, fx) * smooth(gap, gap + 0.03, 1 - fx) * \
            smooth(gap, gap + 0.03, fy) * smooth(gap, gap + 0.03, 1 - fy)
mosaic = mosaic * (0.25 + 0.75 * tile_mask)[..., None]

# ---- 左がRAW(モザイク)、右が現像後。少し傾いた境界でなめらかに切り替え ----
ang = np.deg2rad(14)
d = (u * np.cos(ang) + v * np.sin(ang))
w = smooth(-0.10, 0.10, d + 0.06)
glass = mix(mosaic, scene, w)
# 境界の光の筋(現像の瞬間)
seam = np.exp(-((d + 0.06) / 0.022) ** 2)
glass = glass + seam[..., None] * np.array([1.0, 0.95, 0.85]) * 0.55

# レンズの立体感: 周辺減光 + 左上の反射
r = np.hypot(u, v)
glass = glass * (1 - 0.35 * smooth(0.55, 1.0, r))[..., None]
# 縁に沿った左上の反射光
arc = np.exp(-((r - 0.88) / 0.045) ** 2) * smooth(0.2, 0.9, -(u + v) / np.maximum(r, 1e-3) / 1.414)
glass = glass + arc[..., None] * 0.30
glass_mask = 1 - smooth(R_glass - 1.5 * k, R_glass + 1.5 * k, np.hypot(xx - lx, yy - ly))

# ---- 鏡筒リング(金属のアングルグラデーション + ローレット) ----
rr = np.hypot(xx - lx, yy - ly)
theta = np.arctan2(yy - ly, xx - lx)
R_out = 318 * k; R_in = R_glass
ring_mask = (1 - smooth(R_out - 1.5 * k, R_out + 1.5 * k, rr)) * smooth(R_in - 1.5 * k, R_in + 1.5 * k, rr)
metal = 0.42 + 0.30 * np.cos(2 * (theta + np.pi / 4)) + 0.10 * np.cos(4 * theta)
radial = (rr - R_in) / (R_out - R_in)
knurl_zone = smooth(0.30, 0.34, radial) * (1 - smooth(0.72, 0.76, radial))
knurl = 0.5 + 0.5 * np.cos(theta * 180)
metal = metal * (1 - 0.35 * knurl_zone * knurl)
metal = metal * (0.80 + 0.30 * np.sin(np.pi * np.clip(radial, 0, 1)))
ring = np.stack([metal * 0.93, metal * 0.96, metal * 1.03], -1)
# 内側と外側の細いハイライト
edge_in = np.exp(-((rr - (R_in + 4 * k)) / (2.2 * k)) ** 2)
edge_out = np.exp(-((rr - (R_out - 4 * k)) / (2.2 * k)) ** 2)
ring = ring + (edge_in * 0.35 + edge_out * 0.25)[..., None]
# 内側の黒い縁(ガラスとの間)
inner_black = np.exp(-((rr - R_in) / (5 * k)) ** 2)

# ---- 合成 ----
img = bg.copy()
# レンズの落ち影
shadow = np.exp(-((np.hypot(xx - lx, yy - (ly + 22 * k)) - R_out * 0.92) / (40 * k)).clip(0) ** 2)
shadow = shadow * (np.hypot(xx - lx, yy - (ly + 22 * k)) > R_out * 0.85)
img = img * (1 - 0.45 * shadow)[..., None]
img = mix(img, np.clip(ring, 0, 1), ring_mask)
img = mix(img, np.clip(glass, 0, 1), glass_mask)
img = img * (1 - 0.6 * inner_black)[..., None]
img = np.clip(img, 0, 1)

rgba = np.dstack([img, body]).astype(np.float32)
out = Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA")

# アイコン全体の落ち影 (macOSの標準的な見え方)
alpha = out.split()[3]
sh = Image.new("RGBA", out.size, (0, 0, 0, 0))
sh_alpha = alpha.filter(ImageFilter.GaussianBlur(14 * k)).point(lambda a: int(a * 0.45))
sh.putalpha(sh_alpha)
canvas = Image.new("RGBA", out.size, (0, 0, 0, 0))
canvas.paste(sh, (0, int(10 * k)), sh)
canvas = Image.alpha_composite(canvas, out)
canvas = canvas.resize((1024, 1024), Image.LANCZOS)
canvas.save(__import__("sys").argv[1] if len(__import__("sys").argv) > 1 else "AppIcon.png")

# 確認用: 各サイズを並べたシート(明・暗の背景)
sizes = [512, 128, 64, 32, 16]
W = sum(sizes) + 20 * (len(sizes) + 1)
sheet = Image.new("RGB", (W, 2 * (512 + 40)), (236, 236, 236))
dark = Image.new("RGB", (W, 512 + 40), (40, 40, 44))
sheet.paste(dark, (0, 512 + 40))
x = 20
for s in sizes:
    im = canvas.resize((s, s), Image.LANCZOS)
    for row in range(2):
        sheet.paste(im, (x, row * (552) + 20 + (512 - s) // 2), im)
    x += s + 20
sheet.save("preview.png")
print("ok")
