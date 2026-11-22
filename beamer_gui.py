#!/usr/bin/env python3
"""Qt editor for beamer-gui.

Usage: beamer_gui.py SESSION.json

SESSION.json is written by beamer-gui.el.  Protocol with Emacs, one
JSON object per line:

  stdout  {"items": [...]}        on save, elements in stacking order
  stdin   {"background": "a.pdf"} after Emacs has recompiled the frame

Element coordinates are fractions of the page, origin at the top left.
"""
import json
import os
import shutil
import sys

import pymupdf
from PySide6.QtCore import QPointF, QRectF, QSocketNotifier, Qt
from PySide6.QtGui import (QAction, QBrush, QColor, QImage, QKeySequence, QPainter,
                           QPainterPath, QPen, QPixmap, QPolygonF)
from PySide6.QtWidgets import (QApplication, QGraphicsItem, QGraphicsPathItem,
                               QGraphicsPixmapItem, QGraphicsRectItem,
                               QGraphicsScene, QGraphicsView, QMainWindow,
                               QToolBar)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import beamer_gui_core as core  # noqa: E402

SCENE_WIDTH = 1200.0            # pixels of the rendered page
SHAPE_PEN = QPen(QColor("red"), 3)
HANDLE_COLOR = QColor("#1e88e5")
RAW_HEIGHT = 40                 # textblock heights are unknown: fixed box
MIN_SIZE = 5
HANDLE = 9                      # handle side, pixels
PAGE_MARGIN = 0.25              # scrollable margin around the page, fraction


# ---- rendering ------------------------------------------------------------

def render_pdf(path, width, page=-1):
    """Return PAGE of the PDF at PATH as a QPixmap WIDTH pixels wide."""
    pg = pymupdf.open(path)[page]
    zoom = width / pg.rect.width
    pix = pg.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
    fmt = QImage.Format_RGBA8888 if pix.alpha else QImage.Format_RGB888
    img = QImage(pix.samples, pix.width, pix.height, pix.stride, fmt)
    return QPixmap.fromImage(img.copy())


def load_pixmap(path):
    """Return a QPixmap of the image at PATH, or None if unreadable."""
    if not os.path.exists(path):
        return None
    if path.lower().endswith(".pdf"):
        return render_pdf(path, 800, 0)
    pm = QPixmap(path)
    return None if pm.isNull() else pm


def placeholder_pixmap():
    pm = QPixmap(200, 150)
    pm.fill(QColor("#ccc"))
    return pm


# ---- elements -------------------------------------------------------------

class Handle(QGraphicsRectItem):
    """Draggable square child of an arrow; reports its scene position."""

    def __init__(self, parent, on_move):
        super().__init__(-HANDLE / 2, -HANDLE / 2, HANDLE, HANDLE, parent)
        self.on_move = on_move
        self.placing = False
        self.setBrush(QBrush(HANDLE_COLOR))
        self.setFlags(QGraphicsItem.ItemIsMovable | QGraphicsItem.ItemSendsGeometryChanges)
        self.setZValue(10)

    def itemChange(self, change, value):
        if change == QGraphicsItem.ItemPositionHasChanged and not self.placing:
            self.on_move(self.scenePos())
        return super().itemChange(change, value)

    def place(self, local):
        """Move to LOCAL (parent coordinates) without calling ON_MOVE."""
        self.placing = True
        self.setPos(local)
        self.placing = False


class Element:
    """Behaviour shared by all elements; mixed into a QGraphicsItem.

    Subclasses define KIND and geometry() (the kind-specific fields,
    as page fractions)."""

    kind = None

    def setup(self, editor, data):
        self.editor = editor
        self.id = data["id"]
        self.setFlags(QGraphicsItem.ItemIsMovable | QGraphicsItem.ItemIsSelectable
                      | QGraphicsItem.ItemSendsGeometryChanges)
        if "x" in data:
            self.setPos(editor.to_scene(data["x"], data["y"]))

    def frac_pos(self):
        return self.editor.to_frac(self.pos())

    def to_dict(self):
        return {"kind": self.kind, "id": self.id, **self.geometry()}


class BoxItem(QGraphicsRectItem, Element):
    """Element drawn in its rectangle, resized by 8 handles when selected.

    A drag moves the opposite side or corner by exactly the mouse
    displacement since the press, so resizing cannot run away.  Sizes
    are limited to the page.  Subclasses set ASPECT_LOCKED, HANDLES and
    draw_content(painter, rect)."""

    aspect_locked = False
    handles = core.HANDLES
    CURSORS = {"nw": Qt.SizeFDiagCursor, "se": Qt.SizeFDiagCursor,
               "ne": Qt.SizeBDiagCursor, "sw": Qt.SizeBDiagCursor,
               "n": Qt.SizeVerCursor, "s": Qt.SizeVerCursor,
               "e": Qt.SizeHorCursor, "w": Qt.SizeHorCursor}

    def __init__(self, editor, data, width, height):
        super().__init__(0, 0, width, height)
        self.setup(editor, data)
        self.setAcceptHoverEvents(True)
        self.drag = None            # (handle, start box, press scene pos)

    # geometry
    def box(self):
        return (self.x(), self.y(), self.rect().width(), self.rect().height())

    def set_box(self, x, y, w, h):
        self.prepareGeometryChange()
        self.setPos(x, y)
        self.setRect(0, 0, w, h)

    def aspect(self):
        r = self.rect()
        return r.height() / r.width() if self.aspect_locked else None

    def handle_points(self):
        r = self.rect()

        def point(h):
            x = r.left() if "w" in h else r.right() if "e" in h else r.center().x()
            y = r.top() if "n" in h else r.bottom() if "s" in h else r.center().y()
            return QPointF(x, y)
        return {h: point(h) for h in self.handles}

    def handle_at(self, local):
        if not self.isSelected():
            return None
        for name, p in self.handle_points().items():
            if abs(local.x() - p.x()) <= HANDLE and abs(local.y() - p.y()) <= HANDLE:
                return name
        return None

    def begin_resize(self, handle, scene_pos):
        self.drag = (handle, self.box(), QPointF(scene_pos))

    def resize_drag(self, scene_pos):
        handle, start, press = self.drag
        d = scene_pos - press
        self.set_box(*core.resize_box(start, handle, d.x(), d.y(), aspect=self.aspect(),
                                      min_size=MIN_SIZE * 2,
                                      max_size=(self.editor.W, self.editor.H)))

    def itemChange(self, change, value):
        # A selected element comes to the front, so its handles can be
        # grabbed even where another element overlaps them.
        if change == QGraphicsItem.ItemSelectedHasChanged:
            self.setZValue(1 if value else 0)
        return super().itemChange(change, value)

    # drawing
    def boundingRect(self):
        return self.rect().adjusted(-HANDLE, -HANDLE, HANDLE, HANDLE)

    def paint(self, painter, option, widget=None):
        self.draw_content(painter, self.rect())
        if self.isSelected():
            painter.setPen(QPen(HANDLE_COLOR, 1, Qt.DashLine))
            painter.setBrush(Qt.NoBrush)
            painter.drawRect(self.rect())
            painter.setPen(QPen(Qt.white, 1))
            painter.setBrush(QBrush(HANDLE_COLOR))
            for p in self.handle_points().values():
                painter.drawRect(QRectF(p.x() - HANDLE / 2, p.y() - HANDLE / 2, HANDLE, HANDLE))

    # mouse
    def hoverMoveEvent(self, event):
        handle = self.handle_at(event.pos())
        self.setCursor(self.CURSORS[handle] if handle else Qt.SizeAllCursor)
        super().hoverMoveEvent(event)

    def mousePressEvent(self, event):
        handle = self.handle_at(event.pos())
        if handle and event.button() == Qt.LeftButton:
            self.begin_resize(handle, event.scenePos())
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self.drag:
            self.resize_drag(event.scenePos())
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        if self.drag:
            self.drag = None
            event.accept()
        else:
            super().mouseReleaseEvent(event)

    def frac_size(self):
        return self.editor.to_frac(self.rect().bottomRight())


class ImageItem(BoxItem):
    """Image; height follows width, as \\includegraphics[width=...] does."""
    kind = "image"
    aspect_locked = True

    def __init__(self, editor, data):
        self.file = data["file"]
        path = core.resolve_image(self.file, editor.tex_dir, editor.graphics_path)
        self.pixmap = load_pixmap(path) or placeholder_pixmap()
        width = data["w"] * editor.W
        super().__init__(editor, data, width,
                         width * self.pixmap.height() / self.pixmap.width())

    def draw_content(self, painter, rect):
        painter.setRenderHint(QPainter.SmoothPixmapTransform)
        painter.drawPixmap(rect, self.pixmap, QRectF(self.pixmap.rect()))

    def geometry(self):
        x, y = self.frac_pos()
        return {"file": self.file, "x": x, "y": y, "w": self.frac_size()[0]}


class EllipseItem(BoxItem):
    kind = "ellipse"

    def __init__(self, editor, data):
        super().__init__(editor, data, data["w"] * editor.W, data["h"] * editor.H)

    def draw_content(self, painter, rect):
        painter.setPen(SHAPE_PEN)
        painter.setBrush(Qt.NoBrush)
        painter.drawEllipse(rect)

    def geometry(self):
        (x, y), (w, h) = self.frac_pos(), self.frac_size()
        return {"x": x, "y": y, "w": w, "h": h}


class ArrowItem(QGraphicsPathItem, Element):
    """Arrow from P1 to P2 (local coordinates), one handle per end."""
    kind = "arrow"

    def __init__(self, editor, data):
        super().__init__()
        self.setup(editor, data)
        self.setPen(SHAPE_PEN)
        self.setBrush(QBrush(SHAPE_PEN.color()))
        self.ends = [editor.to_scene(data["x1"], data["y1"]),
                     editor.to_scene(data["x2"], data["y2"])]
        self.handles = [Handle(self, lambda p, i=i: self.move_end(i, p)) for i in (0, 1)]
        self.rebuild()

    def move_end(self, index, scene_pos):
        self.ends[index] = scene_pos - self.pos()
        self.rebuild()

    def rebuild(self):
        start, tip = self.ends
        v = tip - start
        n = max((v.x() ** 2 + v.y() ** 2) ** 0.5, 1e-6)
        along, across = v / n, QPointF(-v.y() / n, v.x() / n)
        base = tip - along * 14
        path = QPainterPath(start)
        path.lineTo(tip)
        path.addPolygon(QPolygonF([tip, base + across * 6, base - across * 6, tip]))
        self.setPath(path)
        for handle, end in zip(self.handles, self.ends):
            handle.place(end)

    def geometry(self):
        (x1, y1), (x2, y2) = (self.editor.to_frac(e + self.pos()) for e in self.ends)
        return {"x1": x1, "y1": y1, "x2": x2, "y2": y2}


class RawItem(BoxItem):
    """Any other tagged block: drawn in the background, only moved and
    narrowed or widened here (its height is set by its content)."""
    kind = "raw"
    handles = ("e", "w")

    def __init__(self, editor, data):
        self.body = data["body"]
        super().__init__(editor, data, data["w"] * editor.W, RAW_HEIGHT)

    def draw_content(self, painter, rect):
        painter.setPen(QPen(HANDLE_COLOR, 1, Qt.DashLine))
        painter.setBrush(Qt.NoBrush)
        painter.drawRect(rect)
        painter.setPen(HANDLE_COLOR)
        painter.drawText(rect.adjusted(4, 2, 0, 0), Qt.AlignLeft | Qt.AlignTop, self.id)

    def geometry(self):
        x, y = self.frac_pos()
        return {"body": self.body, "x": x, "y": y, "w": self.frac_size()[0]}


KINDS = {cls.kind: cls for cls in (ImageItem, EllipseItem, ArrowItem, RawItem)}


# ---- editor window --------------------------------------------------------

class Editor(QMainWindow):
    """One frame: rendered background plus editable elements."""

    def __init__(self, session, listen_stdin=True):
        super().__init__()
        self.tex_dir = session["tex_dir"]
        self.image_dir = session["image_dir"]
        self.graphics_path = session.get("graphics_path", [])
        self.stem = core.safe_stem(session["stem"])
        self.setWindowTitle(f"beamer-gui: {session['stem']}")

        self.scene = QGraphicsScene()
        self.view = QGraphicsView(self.scene)
        self.setCentralWidget(self.view)
        self.background = QGraphicsPixmapItem()
        self.background.setZValue(-1)
        self.scene.addItem(self.background)
        self.set_background(session["background"])

        # Strong references: PySide may otherwise drop the Python
        # wrappers of items created in callbacks.  Order = stacking order.
        self.elements = []
        for data in session["items"]:
            self.add(KINDS[data["kind"]](self, data))

        self.build_toolbar()
        self.resize(int(self.W) + 40, int(self.H) + 90)
        self.view.centerOn(self.W / 2, self.H / 2)
        if listen_stdin and not sys.stdin.isatty():
            self.notifier = QSocketNotifier(sys.stdin.fileno(), QSocketNotifier.Read)
            self.notifier.activated.connect(self.read_stdin)

    # coordinates
    def to_scene(self, fx, fy):
        return QPointF(fx * self.W, fy * self.H)

    def to_frac(self, point):
        return core.to_frac(point.x(), self.W), core.to_frac(point.y(), self.H)

    def set_background(self, pdf):
        pm = render_pdf(pdf, SCENE_WIDTH)
        self.background.setPixmap(pm)
        self.W, self.H = float(pm.width()), float(pm.height())
        m = PAGE_MARGIN
        self.scene.setSceneRect(QRectF(-m * self.W, -m * self.H,
                                       (1 + 2 * m) * self.W, (1 + 2 * m) * self.H))

    def build_toolbar(self):
        toolbar = QToolBar()
        self.addToolBar(toolbar)
        for name, key, slot in [("Arrow", "A", self.add_arrow),
                                ("Ellipse", "E", self.add_ellipse),
                                ("Paste image", QKeySequence.Paste, self.paste),
                                ("Delete", QKeySequence.Delete, self.delete),
                                ("Save", QKeySequence.Save, self.save),
                                ("Quit", QKeySequence.Quit, self.close)]:
            action = QAction(name, self)
            action.setShortcut(QKeySequence(key))
            action.triggered.connect(slot)
            toolbar.addAction(action)

    # elements
    def add(self, item):
        self.scene.addItem(item)
        self.elements.append(item)
        return item

    def managed(self):
        return list(self.elements)

    def ids(self):
        return {e.id for e in self.elements}

    def add_new(self, cls, **geometry):
        return self.add(cls(self, {"id": core.new_id(cls.kind, self.ids()), **geometry}))

    def add_arrow(self):
        self.add_new(ArrowItem, x1=.4, y1=.4, x2=.6, y2=.6)

    def add_ellipse(self):
        self.add_new(EllipseItem, x=.4, y=.4, w=.2, h=.2)

    def paste(self):
        """Add the clipboard image, saved in the image directory.

        A copied image file is copied as is (PDFs stay vector); a
        bitmap is saved as PNG."""
        os.makedirs(self.image_dir, exist_ok=True)
        clipboard = QApplication.clipboard()
        mime = clipboard.mimeData()
        dest = None
        files = [u.toLocalFile() for u in mime.urls()] if mime.hasUrls() else []
        source = next((f for f in files if core.is_image_file(f)), None)
        if source:
            ext = os.path.splitext(source)[1].lower()
            dest = core.unique_image_path(self.image_dir, self.stem, ext)
            shutil.copy(source, dest)
        elif mime.hasImage():
            dest = core.unique_image_path(self.image_dir, self.stem)
            clipboard.image().save(dest, "PNG")
        if dest is None:
            self.statusBar().showMessage("Clipboard has no image")
            return
        self.add(ImageItem(self, {"id": core.new_id("img", self.ids()),
                                  "file": core.rel_to_tex(dest, self.tex_dir),
                                  "x": .3, "y": .3, "w": .3}))
        self.statusBar().showMessage(f"Saved {dest}")

    def delete(self):
        for element in [e for e in self.elements if e.isSelected()]:
            self.scene.removeItem(element)
            self.elements.remove(element)

    # protocol
    def items_dicts(self):
        """Elements in stacking order: later ones are drawn on top."""
        return [e.to_dict() for e in self.elements]

    def save(self):
        sys.stdout.write(json.dumps({"items": self.items_dicts()}) + "\n")
        sys.stdout.flush()
        self.statusBar().showMessage("Saved; recompiling...")

    def read_stdin(self):
        line = sys.stdin.readline()
        if not line:
            self.notifier.setEnabled(False)
            return
        try:
            message = json.loads(line)
        except ValueError:
            return
        if "background" in message:
            self.set_background(message["background"])
            self.statusBar().showMessage("Updated")


def main():
    with open(sys.argv[1]) as f:
        session = json.load(f)
    app = QApplication(sys.argv)
    editor = Editor(session)
    editor.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
