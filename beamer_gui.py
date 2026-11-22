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
from PySide6.QtGui import (QAction, QBrush, QColor, QImage, QKeySequence,
                           QPainterPath, QPen, QPixmap, QPolygonF)
from PySide6.QtWidgets import (QApplication, QGraphicsEllipseItem,
                               QGraphicsItem, QGraphicsPathItem,
                               QGraphicsPixmapItem, QGraphicsRectItem,
                               QGraphicsScene, QGraphicsSimpleTextItem,
                               QGraphicsView, QMainWindow, QToolBar)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import beamer_gui_core as core  # noqa: E402

SCENE_WIDTH = 1200.0            # pixels of the rendered page
SHAPE_PEN = QPen(QColor("red"), 3)
HANDLE_COLOR = QColor("#1e88e5")
RAW_HEIGHT = 40                 # textblock heights are unknown: fixed box
MIN_SIZE = 5


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
    """Draggable square child; reports its scene position to ON_MOVE."""

    def __init__(self, parent, on_move):
        super().__init__(-5, -5, 10, 10, parent)
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

    Subclasses define KIND, resize_to(scene_pos), handle_pos() and
    geometry() (the kind-specific fields, as page fractions)."""

    kind = None

    def setup(self, editor, data):
        self.editor = editor
        self.id = data["id"]
        self.setFlags(QGraphicsItem.ItemIsMovable | QGraphicsItem.ItemIsSelectable
                      | QGraphicsItem.ItemSendsGeometryChanges)
        if "x" in data:
            self.setPos(editor.to_scene(data["x"], data["y"]))

    def add_resize_handle(self):
        self.handle = Handle(self, self.resize_to)
        self.handle.place(self.handle_pos())

    def frac_pos(self):
        return self.editor.to_frac(self.pos())

    def to_dict(self):
        return {"kind": self.kind, "id": self.id, **self.geometry()}


class ImageItem(QGraphicsPixmapItem, Element):
    kind = "image"

    def __init__(self, editor, data):
        self.file = data["file"]
        path = core.resolve_image(self.file, editor.tex_dir, editor.graphics_path)
        super().__init__(load_pixmap(path) or placeholder_pixmap())
        self.setup(editor, data)
        self.setTransformationMode(Qt.SmoothTransformation)
        self.set_width(data["w"] * editor.W)
        self.add_resize_handle()
        self.handle.setScale(1 / self.scale())

    def set_width(self, width):
        self.setScale(max(width, 2 * MIN_SIZE) / self.pixmap().width())

    def handle_pos(self):
        return QPointF(self.pixmap().width(), self.pixmap().height())

    def resize_to(self, scene_pos):
        self.set_width(scene_pos.x() - self.scenePos().x())
        self.handle.place(self.handle_pos())
        self.handle.setScale(1 / self.scale())

    def geometry(self):
        x, y = self.frac_pos()
        return {"file": self.file, "x": x, "y": y,
                "w": core.to_frac(self.pixmap().width() * self.scale(), self.editor.W)}


class EllipseItem(QGraphicsEllipseItem, Element):
    kind = "ellipse"

    def __init__(self, editor, data):
        super().__init__(0, 0, data["w"] * editor.W, data["h"] * editor.H)
        self.setup(editor, data)
        self.setPen(SHAPE_PEN)
        self.add_resize_handle()

    def handle_pos(self):
        return self.rect().bottomRight()

    def resize_to(self, scene_pos):
        size = scene_pos - self.scenePos()
        self.setRect(0, 0, max(size.x(), MIN_SIZE), max(size.y(), MIN_SIZE))
        self.handle.place(self.handle_pos())

    def geometry(self):
        x, y = self.frac_pos()
        w, h = self.editor.to_frac(self.rect().bottomRight())
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


class RawItem(QGraphicsRectItem, Element):
    """Any other tagged block: drawn in the background, only moved here."""
    kind = "raw"

    def __init__(self, editor, data):
        self.body = data["body"]
        super().__init__(0, 0, data["w"] * editor.W, RAW_HEIGHT)
        self.setup(editor, data)
        self.setPen(QPen(HANDLE_COLOR, 1, Qt.DashLine))
        QGraphicsSimpleTextItem(self.id, self).setBrush(QBrush(HANDLE_COLOR))
        self.add_resize_handle()

    def handle_pos(self):
        return self.rect().bottomRight()

    def resize_to(self, scene_pos):
        self.setRect(0, 0, max((scene_pos - self.scenePos()).x(), 2 * MIN_SIZE), RAW_HEIGHT)
        self.handle.place(self.handle_pos())

    def geometry(self):
        x, y = self.frac_pos()
        return {"body": self.body, "x": x, "y": y,
                "w": core.to_frac(self.rect().width(), self.editor.W)}


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
        self.setCentralWidget(QGraphicsView(self.scene))
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
        self.scene.setSceneRect(QRectF(0, 0, self.W, self.H))

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
