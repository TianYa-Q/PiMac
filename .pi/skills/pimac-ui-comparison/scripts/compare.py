#!/usr/bin/env python3
"""保持同比例裁剪并拼接原生截图；坐标为实际 PNG 像素。"""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--before", required=True, type=Path)
parser.add_argument("--after", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--crop", nargs=4, type=int, metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"))
args = parser.parse_args()
images = [Image.open(p).convert("RGB") for p in [args.before, args.after]]
if images[0].size != images[1].size:
    parser.error("两张原图尺寸不同，请重新同条件捕获")
if args.crop:
    left, top, right, bottom = args.crop
    w, h = images[0].size
    if not (0 <= left < right <= w and 0 <= top < bottom <= h):
        parser.error("crop 超出 PNG 实际像素范围")
    images = [im.crop(tuple(args.crop)) for im in images]
if args.output.exists():
    parser.error("output 已存在，请换路径或先 trash 自己的旧输出")
w, h = images[0].size
gap, heading = 24, 64
canvas = Image.new("RGB", (2 * w + gap, h + heading), "#242426")
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", 26)
for index, (im, title) in enumerate(zip(images, ["修改前", "修改后"])):
    x = index * (w + gap)
    draw.text((x + 12, 14), title, font=font, fill="#eeeeef")
    canvas.paste(im, (x, heading))
args.output.parent.mkdir(parents=True, exist_ok=True)
canvas.save(args.output)
print(args.output.resolve())
