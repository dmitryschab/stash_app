"""Assemble the four Data Portability UX mock screens into the PDF TikTok's form wants."""
from PIL import Image, ImageDraw, ImageFont

S = "/private/tmp/claude-501/-Users-dmitryschab-Documents-projects-stash-app/504d3792-863b-4ca8-9d06-66f391e04e9d/scratchpad/"

SCREENS = [
    ("s1_connect.png", "1 · TikTok Connection page",
     "The user opens Stash and chooses to connect their own TikTok account."),
    ("s2_access.png", "2 · Connecting to TikTok",
     "Scope consent: Stash reads Favourite Videos only. Messages, profile and watch history are refused."),
    ("s3_connected.png", "3 · Confirmation of connection",
     "The account is linked; the user's favourites have been imported and new saves keep syncing."),
    ("s4_library.png", "4 · Final output / result",
     "The user's own favourites, organized into a searchable library. Visible only to that user."),
]

PAGE = (1400, 2000)           # portrait page, generous margins around a phone-shaped shot
BG = (255, 255, 255)
INK = (26, 24, 22)
MUTED = (110, 105, 100)


def font(size, bold=False):
    for path in (
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default(size)


def wrap(draw, text, f, width):
    words, lines, line = text.split(), [], ""
    for w in words:
        trial = f"{line} {w}".strip()
        if draw.textlength(trial, font=f) <= width:
            line = trial
        else:
            lines.append(line)
            line = w
    if line:
        lines.append(line)
    return lines


def page(src, title, caption):
    canvas = Image.new("RGB", PAGE, BG)
    draw = ImageDraw.Draw(canvas)

    draw.text((80, 70), "Stash · TikTok Data Portability API — UX mocks", font=font(26), fill=MUTED)
    draw.text((80, 120), title, font=font(46, bold=True), fill=INK)

    y = 190
    for line in wrap(draw, caption, font(27), PAGE[0] - 160):
        draw.text((80, y), line, font=font(27), fill=MUTED)
        y += 38

    shot = Image.open(S + src).convert("RGB")
    top = y + 40
    max_h = PAGE[1] - top - 70
    scale = min((PAGE[0] - 160) / shot.width, max_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    x = (PAGE[0] - shot.width) // 2
    # hairline frame so the screenshot reads as a device shot, not a full-bleed image
    draw.rectangle([x - 1, top - 1, x + shot.width, top + shot.height], outline=(220, 216, 210))
    canvas.paste(shot, (x, top))
    return canvas


pages = [page(*s) for s in SCREENS]
out = S + "stash-dpapi-ux-mocks.pdf"
pages[0].save(out, save_all=True, append_images=pages[1:], resolution=150.0)
print(out)
