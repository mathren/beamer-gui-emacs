#!/usr/bin/env python3
"""Qt editor for beamer-gui.

Usage: beamer_gui.py SESSION.json

SESSION.json is written by beamer-gui.el.  Protocol with Emacs, one
JSON object per line:

  stdout  {"items": [...]}            on save, elements in stacking order
  stdin   {"session": "new.json"}     after Emacs rewrote and recompiled

The frame PDF has the frame twice: page_a with every element (used
to crop pictures of elements of the text), page_b without them (the
background), and page_s with colour swatches.  Element coordinates
are fractions of the page, origin at the top left.
"""
import json
import os
import shutil
import sys

import pymupdf
from PySide6.QtCore import (QEvent, QFileSystemWatcher, QPointF, QProcess, QRectF,
                            QSocketNotifier, Qt, QTimer)
from PySide6.QtGui import (QAction, QBrush, QColor, QIcon, QImage, QKeySequence,
                           QPainter, QPainterPath, QPen, QPixmap, QPolygonF)
from PySide6.QtWidgets import (QApplication, QComboBox, QDialog, QDialogButtonBox,
                               QDockWidget, QDoubleSpinBox, QFileDialog, QFormLayout,
                               QGraphicsItem, QGraphicsPathItem, QGraphicsPixmapItem,
                               QGraphicsRectItem, QGraphicsScene, QGraphicsView,
                               QHBoxLayout, QInputDialog, QLineEdit, QMainWindow, QMenu,
                               QPushButton, QSpinBox, QToolBar, QWidget)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import beamer_gui_core as core  # noqa: E402

SCENE_WIDTH = 1200.0            # pixels of the rendered page
HANDLE_COLOR = QColor("#1e88e5")
DEFAULT_DRAW = QColor("red")
PLACEHOLDER_HEIGHT = 40         # pixels, for elements not measured yet
MIN_SIZE = 5
HANDLE = 9                      # handle side, pixels
PAGE_MARGIN = 0.25              # scrollable margin around the page, fraction
ARROW_HEAD = 4.0                # arrow head length, in line widths


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


def page_words(path, page):
    """Return the words of PAGE of the PDF at PATH, in reading order.

    Each is (X0, Y0, X1, Y1, TEXT) with coordinates in page fractions."""
    pg = pymupdf.open(path)[page]
    w, h = pg.rect.width, pg.rect.height
    return [(x0 / w, y0 / h, x1 / w, y1 / h, text)
            for x0, y0, x1, y1, text, *_ in pg.get_text("words")]


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
        if change == QGraphicsItem.ItemPositionChange and not self.placing:
            editor = self.parentItem().editor
            if editor.snap_active(self.parentItem()):
                point = self.parentItem().mapToScene(value)
                xs, ys = editor.snap_lines(exclude=self.parentItem())
                dx, tx = core.snap_offset([point.x()], xs)
                dy, ty = core.snap_offset([point.y()], ys)
                editor.show_guides(tx, ty)
                return value + QPointF(dx, dy)
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

    Subclasses define KIND and to_dict()."""

    kind = None
    deletable = True            # elements of the user's text are not
    styled = False              # has colour and line options

    def setup(self, editor, data):
        self.editor = editor
        self.id = data["id"]
        self.setFlags(QGraphicsItem.ItemIsMovable | QGraphicsItem.ItemIsSelectable
                      | QGraphicsItem.ItemSendsGeometryChanges)
        if self.styled:
            self.style, self.rest = core.parse_style(data.get("opts", ""), self.kind)

    def options(self):
        return core.format_style(self.style, self.rest, self.kind)

    def style_pen(self):
        ed = self.editor
        color = QColor(ed.color(self.style.get("color"), DEFAULT_DRAW))
        color.setAlphaF(self.style.get("line_opacity", 1.0))
        pen = QPen(color, core.line_width_pt(self.style.get("width")) * ed.px_per_pt)
        dash = self.style.get("dash", "solid")
        if "dot" in dash and "dash" not in dash:
            pen.setStyle(Qt.DotLine)
        elif dash == "dash dot":
            pen.setStyle(Qt.DashDotLine)
        elif "dash" in dash:
            pen.setStyle(Qt.DashLine)
        pen.setCapStyle(Qt.FlatCap)
        return pen

    def frac_pos(self):
        return self.editor.to_frac(self.pos())


class BoxItem(QGraphicsRectItem, Element):
    """Element drawn in its rectangle, resized by handles when selected.

    A drag moves the opposite side or corner by exactly the mouse
    displacement since the press, so resizing cannot run away.  Sizes
    are limited to the page.  RESIZE is "free", "aspect" (keep the
    aspect ratio), "width" (left and right handles only) or "none".
    Subclasses define draw_content(painter, rect)."""

    resize = "free"
    CURSORS = {"nw": Qt.SizeFDiagCursor, "se": Qt.SizeFDiagCursor,
               "ne": Qt.SizeBDiagCursor, "sw": Qt.SizeBDiagCursor,
               "n": Qt.SizeVerCursor, "s": Qt.SizeVerCursor,
               "e": Qt.SizeHorCursor, "w": Qt.SizeHorCursor}

    def __init__(self, editor, data, x, y, width, height):
        super().__init__(0, 0, width, height)
        self.drag = None            # (handle, start box, press scene pos)
        self.setup(editor, data)
        self.setPos(x, y)
        self.setAcceptHoverEvents(True)

    @property
    def handles(self):
        return {"none": (), "width": ("e", "w")}.get(self.resize, core.HANDLES)

    # geometry
    def box(self):
        return (self.x(), self.y(), self.rect().width(), self.rect().height())

    def set_box(self, x, y, w, h):
        self.prepareGeometryChange()
        self.setPos(x, y)
        self.setRect(0, 0, w, h)

    def frac_box(self):
        (x, y), (w, h) = self.editor.to_frac(self.pos()), self.frac_size()
        return [x, y, w, h]

    def frac_size(self):
        return self.editor.to_frac(self.rect().bottomRight())

    def aspect(self):
        r = self.rect()
        return r.height() / r.width() if self.resize == "aspect" else None

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
        if self.editor.snap_active(self):
            d = self.snap_resize(handle, start, d)
        self.set_box(*core.resize_box(start, handle, d.x(), d.y(), aspect=self.aspect(),
                                      min_size=MIN_SIZE * 2,
                                      max_size=(self.editor.W, self.editor.H)))

    def snap_resize(self, handle, start, d):
        """Return the drag D adjusted so the moving edges snap."""
        x, y, w, h = start
        xs, ys = self.editor.snap_lines(exclude=self)
        dx = dy = 0.0
        tx = ty = None
        if "w" in handle or "e" in handle:
            edge = x + d.x() if "w" in handle else x + w + d.x()
            dx, tx = core.snap_offset([edge], xs)
        if "n" in handle or "s" in handle:
            edge = y + d.y() if "n" in handle else y + h + d.y()
            dy, ty = core.snap_offset([edge], ys)
        self.editor.show_guides(tx, ty)
        return d + QPointF(dx, dy)

    def snapped_position(self, pos):
        """Return POS moved so that one of the box lines snaps."""
        r = self.rect()
        lines_x, lines_y = core.box_lines(pos.x(), pos.y(), r.width(), r.height())
        xs, ys = self.editor.snap_lines(exclude=self)
        dx, tx = core.snap_offset(lines_x, xs)
        dy, ty = core.snap_offset(lines_y, ys)
        self.editor.show_guides(tx, ty)
        return pos + QPointF(dx, dy)

    def itemChange(self, change, value):
        if (change == QGraphicsItem.ItemPositionChange and not self.drag
                and self.editor.snap_active(self)):
            return self.snapped_position(value)
        # A selected element comes to the front, so its handles can be
        # grabbed even where another element overlaps them.
        if change == QGraphicsItem.ItemSelectedHasChanged:
            self.setZValue(1 if value else 0)
        return super().itemChange(change, value)

    # drawing
    def boundingRect(self):
        return self.rect().adjusted(-HANDLE, -HANDLE, HANDLE, HANDLE)

    def paint(self, painter, option, widget=None):
        painter.setRenderHint(QPainter.Antialiasing)
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

    def image_file(self):
        """Return the image file shown by this element, or None."""
        return getattr(self, "file", None) or None

    def contextMenuEvent(self, event):
        file = self.image_file()
        if not file:
            return
        command = self.editor.image_command(file)
        menu = QMenu()
        action = menu.addAction(f"Edit {os.path.basename(file)} in {command or '...'}")
        action.setEnabled(bool(command))
        if menu.exec(event.screenPos()) == action:
            self.editor.edit_image(file)


class ImageItem(BoxItem):
    """Image added in the GUI; height follows width, as \\includegraphics does."""
    kind = "image"
    resize = "aspect"

    def __init__(self, editor, data):
        self.file = data["file"]
        path = core.resolve_image(self.file, editor.tex_dir, editor.graphics_path)
        self.pixmap = load_pixmap(path) or placeholder_pixmap()
        width = data["w"] * editor.W
        x, y = editor.to_scene(data["x"], data["y"]).toTuple()
        super().__init__(editor, data, x, y, width,
                         width * self.pixmap.height() / self.pixmap.width())

    def draw_content(self, painter, rect):
        painter.setRenderHint(QPainter.SmoothPixmapTransform)
        painter.drawPixmap(rect, self.pixmap, QRectF(self.pixmap.rect()))

    def to_dict(self):
        x, y = self.frac_pos()
        return {"kind": "image", "id": self.id, "file": self.file,
                "x": x, "y": y, "w": self.frac_size()[0]}


class ShapeItem(BoxItem):
    """Ellipse or rectangle with colour, line and fill options."""
    styled = True

    def __init__(self, editor, data):
        x, y = editor.to_scene(data["x"], data["y"]).toTuple()
        super().__init__(editor, data, x, y, data["w"] * editor.W, data["h"] * editor.H)

    def brush(self):
        fill = self.style.get("fill")
        if not fill:
            return Qt.NoBrush
        color = QColor(self.editor.color(fill, QColor("gray")))
        color.setAlphaF(self.style.get("opacity", 1.0))
        return QBrush(color)

    def draw_content(self, painter, rect):
        painter.setPen(self.style_pen())
        painter.setBrush(self.brush())
        self.draw_shape(painter, rect)

    def to_dict(self):
        (x, y), (w, h) = self.frac_pos(), self.frac_size()
        return {"kind": self.kind, "id": self.id, "x": x, "y": y, "w": w, "h": h,
                "opts": self.options()}


class EllipseItem(ShapeItem):
    kind = "ellipse"

    def draw_shape(self, painter, rect):
        painter.drawEllipse(rect)


class RectItem(ShapeItem):
    kind = "rect"

    def draw_shape(self, painter, rect):
        corners = self.style.get("corners")
        if corners:
            r = core.length_pt(corners) * self.editor.px_per_pt
            painter.drawRoundedRect(rect, r, r)
        else:
            painter.drawRect(rect)


class ArrowItem(QGraphicsPathItem, Element):
    """Arrow between two ends (local coordinates), one handle per end."""
    kind = "arrow"
    styled = True

    def __init__(self, editor, data):
        super().__init__()
        self.setup(editor, data)
        self.ends = [editor.to_scene(data["x1"], data["y1"]),
                     editor.to_scene(data["x2"], data["y2"])]
        self.handles = [Handle(self, lambda p, i=i: self.move_end(i, p)) for i in (0, 1)]
        for handle in self.handles:
            handle.hide()               # shown while the arrow is selected
        self.rebuild()

    def itemChange(self, change, value):
        if change == QGraphicsItem.ItemSelectedHasChanged:
            for handle in self.handles:
                handle.setVisible(bool(value))
            self.setZValue(1 if value else 0)
        return super().itemChange(change, value)

    def move_end(self, index, scene_pos):
        self.ends[index] = scene_pos - self.pos()
        self.rebuild()

    def head(self, tip, toward, pen):
        """Return the arrow head polygon at TIP, pointing away from TOWARD."""
        v = tip - toward
        n = max((v.x() ** 2 + v.y() ** 2) ** 0.5, 1e-6)
        along, across = v / n, QPointF(-v.y() / n, v.x() / n)
        size = max(pen.widthF() * ARROW_HEAD, 8)
        base = tip - along * size
        return QPolygonF([tip, base + across * size / 2, base - across * size / 2, tip])

    def bar(self, at, toward, pen):
        """Return a bar across the line at AT, as TikZ's | tip."""
        v = at - toward
        n = max((v.x() ** 2 + v.y() ** 2) ** 0.5, 1e-6)
        across = QPointF(-v.y() / n, v.x() / n) * max(pen.widthF() * ARROW_HEAD / 2, 4)
        along = v / n * max(pen.widthF() / 2, 1)
        return QPolygonF([at + across - along, at + across + along,
                          at - across + along, at - across - along])

    def rebuild(self):
        start, end = self.ends
        pen = self.style_pen()
        bend = self.style.get("bend")
        path = QPainterPath(start)
        if bend:
            c1, c2 = (QPointF(*c) for c in core.bend_controls(start.toTuple(),
                                                              end.toTuple(), bend))
            path.cubicTo(c1, c2, end)
        else:
            c1, c2 = start, end
            path.lineTo(end)
        first, last = core.tip_ends(self.style.get("tips", "->"))
        self.setPen(pen)
        self.setBrush(Qt.NoBrush)
        heads = QPainterPath()
        for tip, at, toward in ((last, end, c2), (first, start, c1)):
            if tip == "arrow":
                heads.addPolygon(self.head(at, toward, pen))
            elif tip == "bar":
                heads.addPolygon(self.bar(at, toward, pen))
        self.heads = heads
        self.setPath(path)
        for handle, p in zip(self.handles, self.ends):
            handle.place(p)

    def paint(self, painter, option, widget=None):
        painter.setRenderHint(QPainter.Antialiasing)
        super().paint(painter, option, widget)
        painter.setPen(Qt.NoPen)
        painter.setBrush(self.style_pen().color())
        painter.drawPath(self.heads)

    def boundingRect(self):
        return super().boundingRect().united(self.heads.boundingRect()).adjusted(-2, -2, 2, 2)

    def update_style(self):
        self.rebuild()
        self.update()

    def to_dict(self):
        (x1, y1), (x2, y2) = (self.editor.to_frac(e + self.pos()) for e in self.ends)
        return {"kind": "arrow", "id": self.id, "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                "opts": self.options()}


class CropItem(BoxItem):
    """Element shown by its picture cropped from the measured page.

    Used for elements of the user's text ("flow", "textblock"), moved
    ones ("wrap"), and blocks drawn by LaTeX ("text", "raw").  Without
    a measured box (a new text) a placeholder is drawn."""

    deletable = False

    def __init__(self, editor, data, x, y, w, h):
        self.label = data.get("name") or self.kind
        self.file = data.get("file") or None
        super().__init__(editor, data, x, y, w, h)
        self.picture = editor.crop(data["box"]) if data.get("box") else None

    @classmethod
    def from_box(cls, editor, data):
        x, y, w, h = data["box"]
        self = cls(editor, data, x * editor.W, y * editor.H, w * editor.W, h * editor.H)
        self.box0 = list(data["box"])
        self.resize = data.get("resize", "none")
        return self

    def draw_content(self, painter, rect):
        if self.picture is not None:
            painter.drawPixmap(rect, self.picture, QRectF(self.picture.rect()))
        else:
            painter.setPen(QPen(HANDLE_COLOR, 1, Qt.DashLine))
            painter.drawRect(rect)
            painter.drawText(rect.adjusted(4, 2, -2, -2), Qt.AlignLeft | Qt.TextWordWrap,
                             self.placeholder_text())
        if self.isSelected() or self.picture is None:
            painter.setPen(HANDLE_COLOR)
            painter.drawText(rect.adjusted(0, -16, 0, 0), Qt.AlignLeft | Qt.AlignTop,
                             self.label)

    def placeholder_text(self):
        return self.label

    def boundingRect(self):
        return super().boundingRect().adjusted(0, -18, 0, 0)

    def to_dict(self):
        return {"kind": self.kind, "id": self.id, "name": self.label,
                "box": self.frac_box(), "box0": self.box0}


class FlowItem(CropItem):
    kind = "flow"


class WrapItem(CropItem):
    kind = "wrap"


class TextblockItem(CropItem):
    kind = "textblock"


class RawItem(CropItem):
    """Block written by beamer-gui that the editor does not interpret."""
    kind = "raw"
    deletable = True

    def __init__(self, editor, data):
        self.body = data["body"]
        x, y = editor.to_scene(data["x"], data["y"]).toTuple()
        h = data["box"][3] * editor.H if data.get("box") else PLACEHOLDER_HEIGHT
        super().__init__(editor, data, x, y, data["w"] * editor.W, h)
        self.resize = "width"
        self.box0 = list(data["box"]) if data.get("box") else None

    def to_dict(self):
        x, y = self.frac_pos()
        return {"kind": self.kind, "id": self.id, "x": x, "y": y,
                "w": self.frac_size()[0], "body": self.body}


class TextItem(RawItem):
    """Text set by LaTeX in a TikZ node; double-click to edit it."""
    kind = "text"
    styled = True

    def __init__(self, editor, data):
        self.text = data.get("text", "Text")
        super().__init__(editor, dict(data, body=""), )

    def placeholder_text(self):
        return self.text

    def mouseDoubleClickEvent(self, event):
        text, label = self.text, "LaTeX text:"
        while True:
            text, ok = QInputDialog.getMultiLineText(None, "Text", label, text)
            if not ok:
                return
            text = core.escape_percent(text)
            problem = core.text_problem(text)
            if not problem:
                break
            label = f"LaTeX text ({problem}):"
        self.text = text
        self.picture = None           # shown as plain text until saved
        self.update()

    def to_dict(self):
        x, y = self.frac_pos()
        return {"kind": "text", "id": self.id, "x": x, "y": y, "w": self.frac_size()[0],
                "text": self.text, "opts": self.options()}


def make_item(editor, data):
    """Return the element for the session item DATA."""
    kind = data["kind"]
    if kind in ("flow", "wrap", "textblock"):
        return {"flow": FlowItem, "wrap": WrapItem,
                "textblock": TextblockItem}[kind].from_box(editor, data)
    return {"image": ImageItem, "ellipse": EllipseItem, "rect": RectItem,
            "arrow": ArrowItem, "raw": RawItem, "text": TextItem}[kind](editor, data)


# ---- style panel ----------------------------------------------------------

class StylePanel(QDockWidget):
    """Colour, line and fill options of the selected shapes."""

    def __init__(self, editor):
        super().__init__("Style", editor)
        self.editor = editor
        self.loading = False
        form = QFormLayout()
        self.color = self.color_box()
        self.width = self.combo(["default", *core.WIDTHS])
        self.dash = self.combo(list(core.DASHES))
        self.tips = self.combo(list(core.TIPS))
        self.bend = QDoubleSpinBox()
        self.bend.setRange(-90, 90)
        self.bend.setSingleStep(10)
        self.fill = self.color_box("none")
        self.opacity = QDoubleSpinBox()
        self.opacity.setRange(0, 1)
        self.opacity.setSingleStep(0.1)
        self.opacity.setValue(1)
        self.line_opacity = QDoubleSpinBox()
        self.line_opacity.setRange(0, 1)
        self.line_opacity.setSingleStep(0.1)
        self.line_opacity.setValue(1)
        self.corners = QDoubleSpinBox()
        self.corners.setRange(0, 50)
        self.corners.setSuffix(" pt")
        for label, widget in [("Colour", self.color), ("Line", self.width),
                              ("Dash", self.dash), ("Tips", self.tips),
                              ("Bend", self.bend), ("Fill", self.fill),
                              ("Fill opacity", self.opacity), ("Opacity", self.line_opacity),
                              ("Corners", self.corners)]:
            form.addRow(label, widget)
            signal = (widget.currentIndexChanged if isinstance(widget, QComboBox)
                      else widget.valueChanged)
            signal.connect(self.changed)
        body = QWidget()
        body.setLayout(form)
        self.setWidget(body)
        self.setEnabled(False)

    def combo(self, entries):
        box = QComboBox()
        box.addItems(entries)
        return box

    def color_box(self, first="default"):
        box = QComboBox()
        box.addItem(first)
        for name, color in self.editor.colors.items():
            pm = QPixmap(14, 14)
            pm.fill(color)
            box.addItem(QIcon(pm), name)
        return box

    def styled_selection(self):
        # The scene may signal while the editor is being torn down.
        return [e for e in getattr(self.editor, "elements", [])
                if e.isSelected() and e.styled]

    def selection_changed(self):
        items = self.styled_selection()
        self.setEnabled(bool(items))
        if not items:
            return
        item = items[0]
        s = item.style
        self.loading = True
        self.color.setCurrentText(s.get("color") or "default")
        self.width.setCurrentText(s.get("width") or "default")
        self.dash.setCurrentText(s.get("dash") or "solid")
        self.tips.setCurrentText(s.get("tips") or "->")
        self.bend.setValue(s.get("bend") or 0)
        self.fill.setCurrentText(s.get("fill") or "none")
        self.opacity.setValue(s.get("opacity", 1.0))
        self.line_opacity.setValue(s.get("line_opacity", 1.0))
        self.corners.setValue(core.length_pt(s["corners"]) if s.get("corners") else 0)
        arrow = item.kind == "arrow"
        shape = item.kind in ("ellipse", "rect")
        for widget, on in [(self.tips, arrow), (self.bend, arrow), (self.fill, shape),
                           (self.opacity, shape), (self.corners, item.kind == "rect"),
                           (self.width, item.kind != "text"),
                           (self.dash, item.kind != "text")]:
            widget.setEnabled(on)
        self.loading = False

    def current_style(self):
        style = {"color": self.color.currentText(), "width": self.width.currentText(),
                 "dash": self.dash.currentText(), "tips": self.tips.currentText(),
                 "bend": self.bend.value(), "fill": self.fill.currentText(),
                 "opacity": self.opacity.value(), "line_opacity": self.line_opacity.value(),
                 "corners": f"{self.corners.value():g}pt" if self.corners.value() else ""}
        return {k: v for k, v in style.items()
                if v not in ("default", "none", "solid", 0, 0.0, "->", "")
                and not (k in ("opacity", "line_opacity") and v >= 1)}

    def changed(self, *_):
        if self.loading:
            return
        style = self.current_style()
        for item in self.styled_selection():
            keep = {k: v for k, v in style.items()
                    if (k not in ("tips", "bend") or item.kind == "arrow")
                    and (k not in ("fill", "opacity") or item.kind in ("ellipse", "rect"))
                    and (k != "corners" or item.kind == "rect")}
            item.style = keep
            if hasattr(item, "update_style"):
                item.update_style()
            item.update()
            self.editor.last_style[item.kind] = dict(keep)


# ---- frame background -------------------------------------------------------

def color_icon(color):
    pm = QPixmap(14, 14)
    pm.fill(color)
    return QIcon(pm)


class BackgroundDialog(QDialog):
    """Choose the frame's background colour (with a tint) and image.

    The image covers the page; a colour shows where the image is
    transparent, or alone."""

    def __init__(self, editor, background):
        super().__init__(editor)
        self.editor = editor
        self.setWindowTitle("Frame background")
        name, tint = core.split_tint(background.get("color", ""))
        self.color = QComboBox()
        self.color.addItem("none")
        for n, c in editor.colors.items():
            self.color.addItem(color_icon(c), n)
        self.color.setCurrentText(name or "none")
        self.tint = QSpinBox()
        self.tint.setRange(5, 100)
        self.tint.setSingleStep(5)
        self.tint.setSuffix(" %")
        self.tint.setValue(tint)
        self.image = QLineEdit(background.get("image", ""))
        self.image.setReadOnly(True)
        buttons = QHBoxLayout()
        for label, slot in [("Choose...", self.choose), ("Paste", self.paste),
                            ("Clear", self.image.clear)]:
            button = QPushButton(label)
            button.clicked.connect(slot)
            buttons.addWidget(button)
        form = QFormLayout(self)
        form.addRow("Colour", self.color)
        form.addRow("Tint", self.tint)
        form.addRow("Image", self.image)
        form.addRow("", buttons)
        ok = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        ok.accepted.connect(self.accept)
        ok.rejected.connect(self.reject)
        form.addRow(ok)

    def choose(self):
        path, _ = QFileDialog.getOpenFileName(self, "Background image", self.editor.tex_dir,
                                              "Images (*.png *.jpg *.jpeg *.pdf)")
        if path:
            self.image.setText(self.editor.import_image(path))

    def paste(self):
        rel = self.editor.clipboard_image()
        if rel:
            self.image.setText(rel)

    def background(self):
        name = self.color.currentText()
        return {"color": core.join_tint("" if name == "none" else name, self.tint.value()),
                "image": self.image.text()}


# ---- editor window --------------------------------------------------------

class Editor(QMainWindow):
    """One frame: background, pictures of its elements, drawn shapes."""

    def __init__(self, session, listen_stdin=True):
        super().__init__()
        self.scene = QGraphicsScene()
        self.view = QGraphicsView(self.scene)
        self.setCentralWidget(self.view)
        self.background = QGraphicsPixmapItem()
        self.background.setZValue(-1)
        self.scene.addItem(self.background)
        # Strong references: PySide may otherwise drop the Python
        # wrappers of items created in callbacks.  Order = stacking order.
        self.elements = []
        self.last_style = {}
        self.snapping = True        # toolbar toggle
        self.dragging = False       # a mouse button is down in the view
        self.guides = [self.scene.addLine(0, 0, 0, 0, QPen(QColor("#e91e63"), 1, Qt.DashLine))
                       for _ in range(2)]
        for guide in self.guides:
            guide.setZValue(20)
            guide.hide()
        # Images opened in another program: saving them there updates the
        # slide, once the program has finished writing (debounced).
        self.watcher = QFileSystemWatcher(self)
        self.watcher.fileChanged.connect(self.image_changed)
        self.image_timer = QTimer(self)
        self.image_timer.setSingleShot(True)
        self.image_timer.setInterval(500)
        self.image_timer.timeout.connect(self.save)
        self.load(session)
        self.view.viewport().installEventFilter(self)
        self.style_panel = StylePanel(self)
        self.addDockWidget(Qt.RightDockWidgetArea, self.style_panel)
        self.scene.selectionChanged.connect(self.style_panel.selection_changed)
        self.build_toolbar()
        self.resize(int(self.W) + 300, int(self.H) + 90)
        self.view.centerOn(self.W / 2, self.H / 2)
        if listen_stdin and not sys.stdin.isatty():
            self.notifier = QSocketNotifier(sys.stdin.fileno(), QSocketNotifier.Read)
            self.notifier.activated.connect(self.read_stdin)

    # session
    def load(self, session):
        """Show SESSION, replacing any elements shown."""
        for e in self.elements:
            self.scene.removeItem(e)
        self.elements = []
        self.tex_dir = session["tex_dir"]
        self.image_dir = session["image_dir"]
        self.graphics_path = session.get("graphics_path", [])
        self.stem = core.safe_stem(session["stem"])
        self.frame_background = dict(session.get("frame_background")
                                     or {"color": "", "image": ""})
        self.image_editors = {e["ext"].lower(): e["command"]
                              for e in session.get("image_editors", [])}
        self.setWindowTitle(f"beamer-gui: {session['stem']}")
        pdf = session["background"]
        page_b = session.get("page_b", -1)
        page_a = session.get("page_a", -1)
        bg = render_pdf(pdf, SCENE_WIDTH, page_b)
        self.background.setPixmap(bg)
        self.W, self.H = float(bg.width()), float(bg.height())
        self.page_a = render_pdf(pdf, SCENE_WIDTH, page_a) if page_a >= 0 else bg
        self.page_words = page_words(pdf, page_a)
        paper = session.get("paper") or [self.W, self.H]
        self.px_per_pt = self.W / paper[0]
        self.colors = self.sample_colors(pdf, session)
        m = PAGE_MARGIN
        self.scene.setSceneRect(QRectF(-m * self.W, -m * self.H,
                                       (1 + 2 * m) * self.W, (1 + 2 * m) * self.H))
        for data in session["items"]:
            self.add(make_item(self, data))

    def sample_colors(self, pdf, session):
        """Return {name: QColor} from the swatch page of the session."""
        page_s = session.get("page_s", -1)
        if page_s < 0 or not session.get("colors"):
            return {}
        img = render_pdf(pdf, SCENE_WIDTH, page_s).toImage()
        return {c["name"]: img.pixelColor(int(c["x"] * img.width()),
                                          int(c["y"] * img.height()))
                for c in session["colors"]}

    # snapping
    def eventFilter(self, watched, event):
        kind = event.type()
        if kind in (QEvent.MouseButtonPress, QEvent.MouseButtonDblClick):
            scene_pos = self.view.mapToScene(event.position().toPoint())
            ctrl = event.modifiers() & Qt.ControlModifier
            under = self.element_at(scene_pos)
            if (ctrl and kind == QEvent.MouseButtonPress) or (
                    kind == QEvent.MouseButtonDblClick and not isinstance(under, TextItem)):
                self.goto(scene_pos)
                return True
        if kind == QEvent.MouseButtonPress:
            self.dragging = True
        elif kind == QEvent.MouseButtonRelease:
            self.dragging = False
            self.show_guides(None, None)
        return False

    # jumping to the source
    def element_at(self, scene_pos, kinds=None):
        """Return the topmost element whose box holds SCENE_POS, or None.

        KINDS, a class or tuple of classes, limits the elements seen."""
        for e in reversed(self.elements):
            if (isinstance(e, kinds or BoxItem)
                    and QRectF(e.pos(), e.rect().size()).contains(scene_pos)):
                return e
        return None

    def click_info(self, scene_pos):
        """Describe the text clicked at SCENE_POS (see core.click_target).

        A click in an element moved or resized in the GUI is mapped back
        to where it is on the compiled page."""
        x, y = scene_pos.x() / self.W, scene_pos.y() / self.H
        element = self.element_at(scene_pos, CropItem)      # elements with text
        boxes = [e.box0 for e in self.elements if isinstance(e, CropItem)
                 and getattr(e, "box0", None)]
        region = None
        if isinstance(element, CropItem) and getattr(element, "box0", None):
            cx, cy, cw, ch = element.frac_box()
            region = element.box0
            x = region[0] + (x - cx) / max(cw, 1e-6) * region[2]
            y = region[1] + (y - cy) / max(ch, 1e-6) * region[3]
        info = core.click_target(self.page_words, x, y, region,
                                 () if region else boxes)
        if element is not None and element.label in ("includegraphics", "image"):
            info = dict(info, word="")      # letters in a picture are not in the source
        if not element and not info["word"]:
            # No text here: a drawn shape or image jumps to its block.
            element = self.element_at(scene_pos)
        info["element"] = element.id if element else None
        return info

    def goto(self, scene_pos):
        """Ask Emacs to show the source of the text at SCENE_POS."""
        sys.stdout.write(json.dumps({"goto": self.click_info(scene_pos)}) + "\n")
        sys.stdout.flush()

    def snap_active(self, item):
        """Snap ITEM only while the mouse drags it alone."""
        return (self.snapping and self.dragging
                and [e for e in self.elements if e.isSelected()] in ([], [item]))

    def snap_lines(self, exclude=None):
        """Return the vertical and horizontal lines to snap to.

        The page edges and centre, and the edges and centres of every
        element but EXCLUDE (arrows contribute their ends)."""
        xs, ys = [0.0, self.W / 2, self.W], [0.0, self.H / 2, self.H]
        for e in self.elements:
            if e is exclude:
                continue
            if isinstance(e, ArrowItem):
                for end in e.ends:
                    p = end + e.pos()
                    xs.append(p.x())
                    ys.append(p.y())
            else:
                bx, by = core.box_lines(e.x(), e.y(), e.rect().width(), e.rect().height())
                xs.extend(bx)
                ys.extend(by)
        return xs, ys

    def show_guides(self, x, y):
        """Show the snapping guides at X (vertical) and Y (horizontal)."""
        r = self.scene.sceneRect()
        for guide, value, line in [(self.guides[0], x, (x, r.top(), x, r.bottom())),
                                   (self.guides[1], y, (r.left(), y, r.right(), y))]:
            if value is None:
                guide.hide()
            else:
                guide.setLine(*line)
                guide.show()

    def toggle_snapping(self, on):
        self.snapping = on

    def color(self, name, default):
        return self.colors.get(name, default) if name else default

    # coordinates
    def to_scene(self, fx, fy):
        return QPointF(fx * self.W, fy * self.H)

    def to_frac(self, point):
        return core.to_frac(point.x(), self.W), core.to_frac(point.y(), self.H)

    def crop(self, box):
        x, y, w, h = box
        return self.page_a.copy(int(x * self.W), int(y * self.H),
                                max(int(w * self.W), 1), max(int(h * self.H), 1))

    def build_toolbar(self):
        toolbar = QToolBar()
        self.addToolBar(toolbar)
        for name, key, slot in [("Arrow", "A", self.add_arrow),
                                ("Ellipse", "E", self.add_ellipse),
                                ("Rectangle", "R", self.add_rect),
                                ("Text", "T", self.add_text),
                                ("Paste image", QKeySequence.Paste, self.paste),
                                ("Background...", "B", self.edit_background),
                                ("Snap", "S", None),
                                ("Delete", QKeySequence.Delete, self.delete),
                                ("Save", QKeySequence.Save, self.save),
                                ("Quit", QKeySequence.Quit, self.close)]:
            action = QAction(name, self)
            action.setShortcut(QKeySequence(key))
            if slot is None:        # the snapping toggle
                action.setCheckable(True)
                action.setChecked(self.snapping)
                action.toggled.connect(self.toggle_snapping)
            else:
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

    def add_new(self, cls, **data):
        style = self.last_style.get(cls.kind, {})
        data = {"id": core.new_id(cls.kind, self.ids()),
                "opts": core.format_style(style, [], cls.kind) if cls.styled else "",
                **data}
        item = self.add(cls(self, data))
        self.scene.clearSelection()
        item.setSelected(True)
        return item

    def add_arrow(self):
        self.add_new(ArrowItem, x1=.4, y1=.4, x2=.6, y2=.6)

    def add_ellipse(self):
        self.add_new(EllipseItem, x=.4, y=.4, w=.2, h=.2)

    def add_rect(self):
        self.add_new(RectItem, x=.4, y=.4, w=.2, h=.15)

    def add_text(self):
        self.add_new(TextItem, x=.3, y=.3, w=.3, text="Text")

    def import_image(self, path):
        """Return the name of image PATH for LaTeX, copying it if needed.

        Files outside the directory of the LaTeX source are copied to
        the image directory."""
        tex_dir = os.path.realpath(self.tex_dir)
        if os.path.realpath(path).startswith(tex_dir + os.sep):
            return core.rel_to_tex(path, self.tex_dir)
        os.makedirs(self.image_dir, exist_ok=True)
        dest = core.unique_image_path(self.image_dir, self.stem,
                                      os.path.splitext(path)[1].lower())
        shutil.copy(path, dest)
        return core.rel_to_tex(dest, self.tex_dir)

    def clipboard_image(self):
        """Save the clipboard image in the image directory; return its name.

        A copied image file is copied as is (PDFs stay vector); a
        bitmap is saved as PNG.  Return None if there is no image."""
        clipboard = QApplication.clipboard()
        mime = clipboard.mimeData()
        files = [u.toLocalFile() for u in mime.urls()] if mime.hasUrls() else []
        source = next((f for f in files if core.is_image_file(f)), None)
        if source:
            ext = os.path.splitext(source)[1].lower()
            os.makedirs(self.image_dir, exist_ok=True)
            dest = core.unique_image_path(self.image_dir, self.stem, ext)
            shutil.copy(source, dest)
        elif mime.hasImage():
            os.makedirs(self.image_dir, exist_ok=True)
            dest = core.unique_image_path(self.image_dir, self.stem)
            clipboard.image().save(dest, "PNG")
        else:
            self.statusBar().showMessage("Clipboard has no image")
            return None
        return core.rel_to_tex(dest, self.tex_dir)

    def paste(self):
        """Add the clipboard image as a new image element."""
        rel = self.clipboard_image()
        if rel:
            self.add(ImageItem(self, {"id": core.new_id("img", self.ids()),
                                      "file": rel, "x": .3, "y": .3, "w": .3}))
            self.statusBar().showMessage(f"Saved {rel}")

    def image_path(self, file):
        return core.resolve_image(file, self.tex_dir, self.graphics_path)

    def image_command(self, file):
        """Return the program for image FILE, if one is set and installed."""
        ext = os.path.splitext(self.image_path(file))[1].lstrip(".").lower()
        command = self.image_editors.get(ext)
        return command if command and shutil.which(command) else None

    def edit_image(self, file):
        """Open image FILE in its program and recompile when it is saved."""
        path = self.image_path(file)
        command = self.image_command(file)
        if not command:
            self.statusBar().showMessage(
                f"No program for {os.path.basename(path)}: see beamer-gui-image-editors")
            return False
        QProcess.startDetached(command, [path])
        self.watcher.addPath(path)
        self.statusBar().showMessage(f"Editing {os.path.basename(path)} in {command}; "
                                     "saving it there updates the slide")
        return True

    def image_changed(self, path):
        # Some programs replace the file: watch the new one.
        if os.path.exists(path) and path not in self.watcher.files():
            self.watcher.addPath(path)
        self.statusBar().showMessage(f"{os.path.basename(path)} changed; recompiling")
        self.image_timer.start()

    def edit_background(self):
        dialog = BackgroundDialog(self, self.frame_background)
        if dialog.exec():
            self.set_background_spec(dialog.background())

    def set_background_spec(self, background):
        self.frame_background = background
        self.statusBar().showMessage("The background is applied when you save (Ctrl+S)")

    def delete(self):
        for element in [e for e in self.elements if e.isSelected()]:
            if not element.deletable:
                self.statusBar().showMessage(
                    f"{element.label} is part of the slide text: delete it in Emacs")
                continue
            self.scene.removeItem(element)
            self.elements.remove(element)

    # protocol
    def items_dicts(self):
        """Elements in stacking order: later ones are drawn on top."""
        return [e.to_dict() for e in self.elements]

    def save(self):
        sys.stdout.write(json.dumps({"items": self.items_dicts(),
                                     "background": self.frame_background}) + "\n")
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
        self.handle_message(message)

    def handle_message(self, message):
        """Act on a MESSAGE from Emacs: an error to show, or a new session."""
        if "error" in message:
            self.statusBar().showMessage(message["error"])
        if "session" in message:
            with open(message["session"]) as f:
                self.load(json.load(f))
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
