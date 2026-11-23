"""Qt-free helpers of the beamer-gui editor."""
import itertools
import os
import re

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".pdf", ".gif", ".bmp", ".webp"}
LATEX_IMAGE_EXTS = (".pdf", ".png", ".jpg", ".jpeg")  # tried by \includegraphics


def first_free(make_name, is_taken):
    """Return MAKE_NAME(n) for the smallest n >= 1 where IS_TAKEN is false."""
    return next(name for name in map(make_name, itertools.count(1))
                if not is_taken(name))


def unique_image_path(image_dir, stem, ext=".png"):
    """Return the first IMAGE_DIR/STEM-N.EXT that does not exist."""
    return first_free(lambda n: os.path.join(image_dir, f"{stem}-{n}{ext}"),
                      os.path.exists)


def new_id(kind, existing):
    """Return the first identifier KIND<N> not in EXISTING."""
    return first_free(lambda n: f"{kind}{n}", existing.__contains__)


def rel_to_tex(path, tex_dir):
    """Return PATH relative to TEX_DIR, with / separators, for LaTeX."""
    return os.path.relpath(path, tex_dir).replace(os.sep, "/")


def resolve_image(file, tex_dir, graphics_path=()):
    """Return the file an \\includegraphics{FILE} refers to.

    As LaTeX does, look in TEX_DIR then in each GRAPHICS_PATH directory,
    adding the usual extensions when FILE has none.  If nothing exists,
    return the first candidate."""
    if os.path.isabs(file):
        dirs = [""]
    else:
        dirs = [os.path.join(tex_dir, d) for d in ("", *graphics_path)]
    exts = ("",) if os.path.splitext(file)[1] else LATEX_IMAGE_EXTS
    candidates = [os.path.normpath(os.path.join(d, file) + e) for d in dirs for e in exts]
    return next((c for c in candidates if os.path.exists(c)), candidates[0])


def clamp(value, low=-0.5, high=1.5):
    """Return VALUE limited to [LOW, HIGH]: elements may overhang the page."""
    return max(low, min(high, value))


def to_frac(pixels, size):
    """Return PIXELS as a clamped fraction of SIZE, rounded to 4 decimals."""
    return round(clamp(pixels / size), 4)


HANDLES = ("nw", "n", "ne", "e", "se", "s", "sw", "w")


def resize_box(box, handle, dx, dy, aspect=None, min_size=10.0, max_size=None):
    """Return BOX (x, y, w, h) resized by dragging HANDLE by DX, DY.

    HANDLE is a compass point of HANDLES; the opposite side or corner
    stays fixed.  With ASPECT (height / width) the ratio is kept: an
    edge handle drives its own dimension, a corner the one moved most.
    Sizes are kept between MIN_SIZE and MAX_SIZE (w, h)."""
    x, y, w, h = box
    left, top, right, bottom = x, y, x + w, y + h
    if "w" in handle:
        left += dx
    if "e" in handle:
        right += dx
    if "n" in handle:
        top += dy
    if "s" in handle:
        bottom += dy
    w, h = right - left, bottom - top
    if aspect:
        horizontal = handle in ("e", "w") or (
            len(handle) == 2 and abs(dx) * aspect >= abs(dy))
        if horizontal:
            h = w * aspect
        else:
            w = h / aspect
    max_w, max_h = max_size or (float("inf"), float("inf"))
    w = min(max(w, min_size), max_w)
    h = min(max(h, min_size), max_h)
    if aspect:  # clamping one side must not break the ratio
        if h != w * aspect:
            w, h = min(w, h / aspect), min(h, w * aspect)
    new_x = x + (box[2] - w) if "w" in handle else x
    new_y = y + (box[3] - h) if "n" in handle else y
    return new_x, new_y, w, h


def is_image_file(path):
    """Return True if PATH has an image extension."""
    return os.path.splitext(path)[1].lower() in IMAGE_EXTS


def safe_stem(stem):
    """Return STEM reduced to characters safe in file names."""
    return re.sub(r"[^A-Za-z0-9_-]+", "-", stem).strip("-") or "img"


# ---- TikZ options of drawn shapes ------------------------------------------
#
# A shape's options are a comma-separated TikZ list such as
# "draw=Maroon, very thick, dashed, bend left=20, my key=1".  The
# editor manages a few of them (STYLE_KEYS); the others are kept,
# in their order, after the managed ones.

WIDTHS = {"ultra thin": 0.1, "very thin": 0.2, "thin": 0.4, "semithick": 0.6,
          "thick": 0.8, "very thick": 1.2, "ultra thick": 1.6}
DASHES = ("solid", "dashed", "dotted", "densely dashed", "densely dotted",
          "loosely dashed", "loosely dotted", "dash dot")
TIPS = ("->", "<-", "<->", "-")
BASE_LINE_WIDTH = 2.0   # pt, from the gui arrow/ellipse/rect styles
COLOR_KEY = {"arrow": "draw", "ellipse": "draw", "rect": "draw", "text": "text"}
STYLE_KEYS = ("color", "width", "dash", "tips", "bend", "fill", "opacity")


def split_options(options):
    """Split the TikZ option list OPTIONS at top-level commas."""
    parts, depth, start = [], 0, 0
    for i, c in enumerate(options):
        if c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(options[start:i])
            start = i + 1
    parts.append(options[start:])
    return [p.strip() for p in parts if p.strip()]


def parse_style(options, kind):
    """Return (STYLE, REST) for the options of a shape of KIND.

    STYLE maps the managed keys of STYLE_KEYS to their values;
    REST lists the other options, unchanged."""
    style, rest = {}, []
    color_key = COLOR_KEY.get(kind)
    for part in split_options(options or ""):
        key, _, value = (s.strip() for s in part.partition("="))
        if color_key and key == color_key and value:
            style["color"] = value
        elif part in WIDTHS:
            style["width"] = part
        elif key == "line width" and value:
            style["width"] = value
        elif part in DASHES:
            style["dash"] = part
        elif kind == "arrow" and part in TIPS:
            style["tips"] = part
        elif kind == "arrow" and key in ("bend left", "bend right"):
            angle = float(value) if value else 30.0
            style["bend"] = angle if key == "bend left" else -angle
        elif kind in ("ellipse", "rect") and key == "fill" and value:
            style["fill"] = value
        elif kind in ("ellipse", "rect") and key == "fill opacity" and value:
            style["opacity"] = float(value)
        else:
            rest.append(part)
    return style, rest


def format_style(style, rest, kind):
    """Return the option list of a shape of KIND with STYLE and REST."""
    parts = []
    if style.get("color"):
        parts.append(f"{COLOR_KEY[kind]}={style['color']}")
    width = style.get("width")
    if width:
        parts.append(width if width in WIDTHS else f"line width={width}")
    if style.get("dash") and style["dash"] != "solid":
        parts.append(style["dash"])
    if kind == "arrow" and style.get("tips"):
        parts.append(style["tips"])
    if kind == "arrow" and style.get("bend"):
        bend = style["bend"]
        side = "left" if bend > 0 else "right"
        parts.append(f"bend {side}={abs(bend):g}")
    if kind in ("ellipse", "rect") and style.get("fill"):
        parts.append(f"fill={style['fill']}")
        if style.get("opacity") is not None and style["opacity"] < 1:
            parts.append(f"fill opacity={style['opacity']:g}")
    return ", ".join(parts + list(rest))


def line_width_pt(width):
    """Return the line width WIDTH (a TikZ keyword or length) in points."""
    if not width:
        return BASE_LINE_WIDTH
    if width in WIDTHS:
        return WIDTHS[width]
    m = re.match(r"\s*([0-9.]+)\s*(pt|mm|cm)?\s*$", width)
    if not m:
        return BASE_LINE_WIDTH
    return float(m.group(1)) * {"pt": 1, None: 1, "mm": 2.84528, "cm": 28.4528}[m.group(2)]


def bend_controls(p1, p2, angle):
    """Return the Bezier control points of a TikZ "to[bend ...]" path.

    P1 and P2 are (x, y) in screen coordinates (y down); ANGLE is
    positive for bend left, as TikZ sees it with y up."""
    import math
    (x1, y1), (x2, y2) = p1, p2
    dx, dy = x2 - x1, -(y2 - y1)            # TikZ orientation, y up
    d = math.hypot(dx, dy)
    a = math.atan2(dy, dx)
    k = 0.3915 * d                          # TikZ looseness 1
    out_a = a + math.radians(angle)
    in_a = a + math.pi - math.radians(angle)
    c1 = (x1 + k * math.cos(out_a), y1 - k * math.sin(out_a))
    c2 = (x2 + k * math.cos(in_a), y2 - k * math.sin(in_a))
    return c1, c2


# ---- snapping --------------------------------------------------------------

SNAP_TOLERANCE = 6.0    # pixels


def box_lines(x, y, w, h):
    """Return the vertical and horizontal lines of a box: edges and centre."""
    return (x, x + w / 2, x + w), (y, y + h / 2, y + h)


def snap_offset(values, targets, tolerance=SNAP_TOLERANCE):
    """Return (DELTA, TARGET) moving one of VALUES onto one of TARGETS.

    The smallest move within TOLERANCE wins; (0, None) if none."""
    best = None
    for v in values:
        for t in targets:
            d = t - v
            if abs(d) <= tolerance and (best is None or abs(d) < abs(best[0])):
                best = (d, t)
    return best or (0.0, None)


# ---- frame background --------------------------------------------------------

def split_tint(color):
    """Return (NAME, TINT) of an xcolor expression NAME!TINT (TINT 100 if none)."""
    name, _, tint = (color or "").partition("!")
    try:
        return name, int(float(tint)) if tint else 100
    except ValueError:
        return color, 100


def join_tint(name, tint):
    """Return the xcolor expression for NAME at TINT percent, or ""."""
    if not name:
        return ""
    return name if tint >= 100 else f"{name}!{tint}"


# ---- LaTeX text typed by the user ------------------------------------------------

def escape_percent(text):
    """Return TEXT with unescaped % escaped: a % would comment out the
    end of the TikZ line holding the text."""
    return re.sub(r"(?<!\\)((?:\\\\)*)%", r"\1\\%", text)


def text_problem(text):
    """Return why TEXT cannot be put in a TikZ node, or None.

    Braces must balance (escaped \\{ and \\} do not count) and the
    text must not end with an unpaired backslash."""
    depth = 0
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\":
            if i + 1 == len(text):
                return "the text ends with a backslash"
            i += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth < 0:
                return "a } has no matching {"
        i += 1
    return "a { has no matching }" if depth else None


# ---- clicked words -------------------------------------------------------------

def normalize_word(text):
    """Return TEXT as it would appear in the LaTeX source.

    Ligatures are expanded (NFKC), surrounding punctuation dropped, and
    a hyphen ending a line removed."""
    import unicodedata
    text = unicodedata.normalize("NFKC", text)
    if text.endswith("-") and len(text) > 1:
        text = text[:-1]
    # Bullets, punctuation, % (\% in the source) and the like around it.
    return re.sub(r"^[^\w]+|[^\w]+$", "", text)


def inside(box, x, y):
    """Return True if point X, Y is inside BOX (x, y, w, h)."""
    bx, by, bw, bh = box
    return bx <= x <= bx + bw and by <= y <= by + bh


def click_target(words, x, y, region=None, exclude=(), tolerance=0.01):
    """Describe the word clicked at X, Y for the Emacs side.

    WORDS are (X0, Y0, X1, Y1, TEXT) in page fractions, in reading
    order.  Only words in REGION (a box), or with no REGION outside all
    EXCLUDE boxes, count: those of the clicked element, or the text
    outside elements.  Return a dict: word, nth (earlier occurrences of
    the same word there), before and after (two neighbours each)."""
    def counts(w):
        cx, cy = (w[0] + w[2]) / 2, (w[1] + w[3]) / 2
        if region is not None:
            return inside(region, cx, cy)
        return not any(inside(b, cx, cy) for b in exclude)

    def distance(w):
        dx = max(w[0] - x, 0, x - w[2])
        dy = max(w[1] - y, 0, y - w[3])
        return (dx * dx + dy * dy) ** 0.5

    pool = [(w, normalize_word(w[4])) for w in words if counts(w)]
    pool = [(w, t) for w, t in pool if t]
    if not pool:
        return {"word": "", "raw": "", "nth": 0, "before": [], "after": []}
    i = min(range(len(pool)), key=lambda k: distance(pool[k][0]))
    if distance(pool[i][0]) > tolerance:
        return {"word": "", "raw": "", "nth": 0, "before": [], "after": []}
    word = pool[i][1]
    raw = pool[i][0][4]
    return {"word": word, "raw": raw if re.search(r"[\\{}]", raw) else "",
            "nth": sum(1 for _, t in pool[:i] if t == word),
            "before": [t for _, t in pool[max(0, i - 2):i]],
            "after": [t for _, t in pool[i + 1:i + 3]]}
