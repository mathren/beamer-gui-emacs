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
