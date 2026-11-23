"""Tests for beamer_gui_core and, offscreen, the Qt editor."""
import gc
import json
import os
import shutil
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import beamer_gui_core as core  # noqa: E402

TOL = 2e-3  # pixel rounding at SCENE_WIDTH


# ---- core: files and ids ---------------------------------------------------

def test_unique_image_path(tmp_path):
    first = core.unique_image_path(str(tmp_path), "lec-f3")
    assert first.endswith("lec-f3-1.png")
    open(first, "w").close()
    assert core.unique_image_path(str(tmp_path), "lec-f3").endswith("lec-f3-2.png")
    assert core.unique_image_path(str(tmp_path), "lec-f3", ".pdf").endswith("lec-f3-1.pdf")


def test_rel_to_tex(tmp_path):
    path = os.path.join(str(tmp_path), "fig_slides", "a.png")
    assert core.rel_to_tex(path, str(tmp_path)) == "fig_slides/a.png"


def test_resolve_image_graphicspath(tmp_path):
    os.makedirs(tmp_path / "fig_slides")
    (tmp_path / "fig_slides" / "hr.png").write_text("")
    (tmp_path / "local.png").write_text("")
    tex, gp = str(tmp_path), ["./fig_slides/"]
    in_fig = str(tmp_path / "fig_slides" / "hr.png")
    assert core.resolve_image("hr", tex, gp) == in_fig
    assert core.resolve_image("hr.png", tex, gp) == in_fig
    assert core.resolve_image("local.png", tex, gp) == str(tmp_path / "local.png")
    assert core.resolve_image("missing", tex, gp).endswith("missing.pdf")


def test_new_id_and_safe_stem():
    assert core.new_id("img", set()) == "img1"
    assert core.new_id("img", {"img1", "img2"}) == "img3"
    assert core.safe_stem("my lec/f1") == "my-lec-f1"
    assert core.safe_stem("///") == "img"


def test_to_frac_clamps_and_rounds():
    assert core.to_frac(600, 1200) == 0.5
    assert core.to_frac(1 / 3 * 1200, 1200) == 0.3333
    assert core.to_frac(-5000, 1200) == -0.5


# ---- core: resizing and snapping ---------------------------------------------

def test_resize_box():
    box = (10, 10, 100, 50)
    assert core.resize_box(box, "se", 20, 0, aspect=0.5) == (10, 10, 120, 60)
    assert core.resize_box(box, "nw", -20, 0, aspect=0.5) == (-10, 0, 120, 60)
    assert core.resize_box(box, "n", 0, -10) == (10, 0, 100, 60)
    assert core.resize_box(box, "w", 500, 0, min_size=10) == (100, 10, 10, 50)
    assert core.resize_box(box, "e", 5000, 0, aspect=0.5,
                           max_size=(1200, 675)) == (10, 10, 1200, 600)


def test_snap_offset():
    assert core.snap_offset([10, 60], [63, 200]) == (3, 63)      # closest wins
    assert core.snap_offset([10], [17]) == (0.0, None)            # too far
    assert core.snap_offset([10, 20], [14, 21]) == (1, 21)
    assert core.box_lines(0, 10, 100, 40) == ((0, 50, 100), (10, 30, 50))


# ---- core: TikZ options --------------------------------------------------------

def test_style_roundtrip_keeps_unknown_options():
    opts = "draw=Maroon, very thick, dashed, bend left=20, -{Stealth[length=3mm]}, my key=1"
    style, rest = core.parse_style(opts, "arrow")
    assert style == {"color": "Maroon", "width": "very thick", "dash": "dashed", "bend": 20.0}
    assert rest == ["-{Stealth[length=3mm]}", "my key=1"]
    assert core.format_style(style, rest, "arrow") == opts


def test_style_per_kind():
    style, rest = core.parse_style("draw=bblue, fill=Yellow, fill opacity=0.5, ->", "rect")
    assert style == {"color": "bblue", "fill": "Yellow", "opacity": 0.5}
    assert rest == ["->"]                     # tips only managed for arrows
    style, _ = core.parse_style("text=red", "text")
    assert style == {"color": "red"}
    assert core.format_style({"bend": -30}, [], "arrow") == "bend right=30"
    assert core.format_style({"tips": "<->", "dash": "solid"}, [], "arrow") == "<->"


def test_tint():
    assert core.split_tint("bblue!20") == ("bblue", 20)
    assert core.split_tint("bblue") == ("bblue", 100)
    assert core.split_tint("") == ("", 100)
    assert core.join_tint("bblue", 20) == "bblue!20"
    assert core.join_tint("bblue", 100) == "bblue"
    assert core.join_tint("", 50) == ""


def test_typed_text_checks():
    assert core.escape_percent("100%") == "100\\%"
    assert core.escape_percent("50\\% off") == "50\\% off"          # already escaped
    assert core.escape_percent("a\\\\%b") == "a\\\\\\%b"        # \\ then %
    assert core.text_problem("{a} \\{ \\}") is None
    assert core.text_problem("{") == "a { has no matching }"
    assert core.text_problem("a}") == "a } has no matching {"
    assert core.text_problem("a\\") == "the text ends with a backslash"


def test_click_target():
    words = [(0.1, 0.1, 0.2, 0.15, "▶Second"), (0.25, 0.1, 0.3, 0.15, "item,"),
             (0.1, 0.5, 0.2, 0.55, "Second"), (0.25, 0.5, 0.3, 0.55, "ﬁnal-"),
             (0.6, 0.6, 0.7, 0.65, "inbox")]
    got = core.click_target(words, 0.15, 0.52, exclude=[(0.55, 0.55, 0.3, 0.3)])
    assert got == {"word": "Second", "raw": "", "nth": 1, "before": ["Second", "item"],
                   "after": ["final"]}
    got = core.click_target(words, 0.65, 0.62, region=(0.55, 0.55, 0.3, 0.3))
    assert got["word"] == "inbox" and got["nth"] == 0 and got["before"] == []
    assert core.click_target(words, 0.9, 0.9)["word"] == ""       # nothing near
    assert core.normalize_word("100%") == "100"


def test_more_styles():
    style, rest = core.parse_style("-latex, draw opacity=0.5, rounded corners=6pt", "rect")
    assert style == {"line_opacity": 0.5, "corners": "6pt"} and rest == ["-latex"]
    style, rest = core.parse_style("|-|, draw opacity=0.5", "arrow")
    assert style == {"tips": "|-|", "line_opacity": 0.5}
    assert core.format_style({"corners": "4pt", "line_opacity": 1}, [], "rect") == \
        "rounded corners=4pt"
    assert core.tip_ends("|->") == ("bar", "arrow")
    assert core.tip_ends("-") == (None, None)
    assert core.length_pt("1mm") == 2.84528 and core.length_pt("x") == 4.0


def test_line_width_and_bend():
    assert core.line_width_pt(None) == core.BASE_LINE_WIDTH
    assert core.line_width_pt("thick") == 0.8
    assert abs(core.line_width_pt("1mm") - 2.84528) < 1e-6
    c1, c2 = core.bend_controls((0, 0), (100, 0), 30)
    assert c1[1] < 0 and c2[1] < 0                   # bend left goes up on screen
    c1, _ = core.bend_controls((0, 0), (100, 0), -30)
    assert c1[1] > 0


# ---- offscreen GUI ---------------------------------------------------------

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QPointF  # noqa: E402
import beamer_gui  # noqa: E402

SWATCHES = {"bblue": "144b7a", "Maroon": "af3235"}
ITEMS = [
    {"kind": "image", "id": "img1", "file": "fig_slides/g.png", "x": 0.1, "y": 0.2, "w": 0.3},
    {"kind": "arrow", "id": "arrow1", "x1": 0.6, "y1": 0.2, "x2": 0.2, "y2": 0.7,
     "opts": "draw=Maroon, thick, my key=1"},
    {"kind": "ellipse", "id": "ellipse1", "x": 0.4, "y": 0.4, "w": 0.2, "h": 0.1, "opts": ""},
    {"kind": "rect", "id": "rect1", "x": 0.7, "y": 0.7, "w": 0.1, "h": 0.1,
     "opts": "draw=bblue, fill=Maroon, fill opacity=0.5"},
    {"kind": "text", "id": "text1", "x": 0.05, "y": 0.8, "w": 0.3, "text": "Hi $x$",
     "opts": "text=bblue", "box": [0.05, 0.8, 0.3, 0.05]},
    {"kind": "raw", "id": "t1", "x": 0.5, "y": 0.5, "w": 0.3, "body": "$x$"},
    {"kind": "flow", "id": "c1", "name": "block", "box": [0.1, 0.5, 0.3, 0.2],
     "resize": "width"},
    {"kind": "wrap", "id": "w1", "name": "includegraphics", "box": [0.6, 0.05, 0.2, 0.1],
     "resize": "aspect"},
]


@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    return QApplication.instance() or QApplication([])


def solid_image(color, w=40, h=40):
    from PySide6.QtGui import QColor, QImage
    img = QImage(w, h, QImage.Format_RGB32)
    img.fill(QColor(color))
    return img


@pytest.fixture
def session(app, tmp_path):
    if not shutil.which("pdflatex"):
        pytest.skip("pdflatex missing")
    defs = "".join(f"\\definecolor{{{n}}}{{HTML}}{{{c}}}" for n, c in SWATCHES.items())
    swatches = "".join(f"\\textcolor{{{n}}}{{\\rule{{3mm}}{{3mm}}}}\\hspace{{1mm}}"
                       for n in SWATCHES)
    (tmp_path / "bg.tex").write_text(
        "\\documentclass{beamer}" + defs + "\\begin{document}"
        "\\begin{frame}A\\end{frame}\\begin{frame}B\\end{frame}"
        "\\begin{frame}[plain]\\noindent " + swatches + "\\end{frame}\\end{document}")
    subprocess.run(["pdflatex", "-interaction=nonstopmode", "bg.tex"], cwd=tmp_path,
                   check=True, stdout=subprocess.DEVNULL)
    os.makedirs(tmp_path / "fig_slides")
    solid_image("green", 100, 50).save(str(tmp_path / "fig_slides" / "g.png"))
    # Swatch centres: \noindent at the 1cm margin, 3mm squares 1mm apart,
    # on the first line of a plain frame (top margin of beamer's plain frame).
    import pymupdf
    page = pymupdf.open(str(tmp_path / "bg.pdf"))[2]
    rects = [d["rect"] for d in page.get_drawings() if abs(d["rect"].width - 8.5) < 0.5]
    colors = [{"name": n, "x": r.x0 / page.rect.width + 0.004,
               "y": (r.y0 + r.height / 2) / page.rect.height}
              for n, r in zip(SWATCHES, sorted(rects, key=lambda r: r.x0))]
    return {"background": str(tmp_path / "bg.pdf"), "page_a": 0, "page_b": 1, "page_s": 2,
            "paper": [page.rect.width, page.rect.height], "colors": colors,
            "tex_dir": str(tmp_path), "image_dir": str(tmp_path / "fig_slides"),
            "stem": "lec-f1", "items": [dict(i) for i in ITEMS],
            "frame_background": {"color": "bblue!20", "image": ""}}


@pytest.fixture
def editor(session):
    return beamer_gui.Editor(session, listen_stdin=False)


def by_id(editor):
    return {d["id"]: d for d in editor.items_dicts()}


def elements(editor):
    return {e.id: e for e in editor.managed()}


def assert_close(d, **expected):
    for key, value in expected.items():
        assert abs(d[key] - value) < TOL, (key, d[key], value)


def test_roundtrip(editor):
    out = by_id(editor)
    for item in ITEMS:
        got = out[item["id"]]
        for key, value in item.items():
            if key in ("box", "resize", "name"):
                continue
            if isinstance(value, float):
                assert_close(got, **{key: value})
            else:
                assert got[key] == value, (item["id"], key)
    assert out["c1"]["box"] == out["c1"]["box0"] == ITEMS[6]["box"]


def test_colors_sampled_from_swatches(editor):
    for name, hexa in SWATCHES.items():
        c = editor.colors[name]
        want = tuple(int(hexa[i:i + 2], 16) for i in (0, 2, 4))
        assert all(abs(a - b) <= 3 for a, b in zip((c.red(), c.green(), c.blue()), want))
    assert elements(editor)["arrow1"].style_pen().color() == editor.colors["Maroon"]


def drag_handle(item, handle, dx, dy, steps=10):
    ed = item.editor
    start = item.mapToScene(item.handle_points()[handle])
    item.begin_resize(handle, start)
    for i in range(1, steps + 1):
        item.resize_drag(start + QPointF(dx * ed.W, dy * ed.H) * (i / steps))
    item.drag = None


@pytest.mark.parametrize("handle", core.HANDLES)
def test_resize_every_handle_keeps_opposite_fixed(editor, handle):
    item = elements(editor)["ellipse1"]          # x .4 y .4 w .2 h .1
    drag_handle(item, handle, 0.05, 0.05)
    out = by_id(editor)["ellipse1"]
    want_x = {"w": (0.45, 0.15), "e": (0.4, 0.25)}
    want_y = {"n": (0.45, 0.05), "s": (0.4, 0.15)}
    x, w = next((v for k, v in want_x.items() if k in handle), (0.4, 0.2))
    y, h = next((v for k, v in want_y.items() if k in handle), (0.4, 0.1))
    assert_close(out, x=x, w=w, y=y, h=h)


def test_resize_image_keeps_aspect_and_follows_mouse(editor):
    item = elements(editor)["img1"]
    w0 = item.rect().width()
    drag_handle(item, "e", 0.1, 0, steps=50)
    assert abs(item.rect().width() - (w0 + 0.1 * editor.W)) < 1e-6
    assert abs(item.rect().height() / item.rect().width() - 0.5) < 1e-6
    drag_handle(item, "e", -0.1, 0, steps=50)
    assert abs(item.rect().width() - w0) < 1e-6


def test_resize_modes_of_text_elements(editor):
    el = elements(editor)
    assert set(el["c1"].handle_points()) == {"e", "w"}       # block: width only
    assert len(el["w1"].handle_points()) == 8                # image: all handles
    assert set(el["t1"].handle_points()) == {"e", "w"}


def test_moving_text_element_reports_box(editor):
    c1 = elements(editor)["c1"]
    c1.setPos(c1.x() + 0.1 * editor.W, c1.y())
    out = by_id(editor)["c1"]
    assert_close(dict(zip("xywh", out["box"])), x=0.2, y=0.5, w=0.3, h=0.2)
    assert out["box0"] == [0.1, 0.5, 0.3, 0.2]


def test_text_elements_are_not_deletable(editor):
    el = elements(editor)
    el["c1"].setSelected(True)
    el["ellipse1"].setSelected(True)
    editor.delete()
    ids = editor.ids()
    assert "c1" in ids and "ellipse1" not in ids


def test_style_panel_applies_to_selection(editor):
    el = elements(editor)
    editor.scene.clearSelection()
    el["ellipse1"].setSelected(True)
    panel = editor.style_panel
    panel.color.setCurrentText("bblue")
    panel.dash.setCurrentText("dashed")
    panel.fill.setCurrentText("Maroon")
    panel.opacity.setValue(0.3)
    assert by_id(editor)["ellipse1"]["opts"] == \
        "draw=bblue, dashed, fill=Maroon, fill opacity=0.3"
    editor.scene.clearSelection()
    el["arrow1"].setSelected(True)
    panel.tips.setCurrentText("<->")
    panel.bend.setValue(-20)
    # Options the panel does not manage are kept.
    assert by_id(editor)["arrow1"]["opts"] == \
        "draw=Maroon, thick, <->, bend right=20, my key=1"


def test_text_dialog_rejects_bad_text(editor, monkeypatch):
    answers = iter([("{oops", True), ("50% {ok}", True)])
    labels = []

    def dialog(parent, title, label, text):
        labels.append(label)
        return next(answers)
    monkeypatch.setattr(beamer_gui.QInputDialog, "getMultiLineText", staticmethod(dialog))
    item = elements(editor)["text1"]
    item.mouseDoubleClickEvent(None)
    assert item.text == "50\\% {ok}"
    assert "no matching" in labels[1]


def test_new_shapes_take_last_style(editor):
    editor.add_rect()
    editor.style_panel.color.setCurrentText("Maroon")
    editor.add_rect()
    rects = [d for d in editor.items_dicts() if d["kind"] == "rect"]
    assert rects[-1]["opts"].startswith("draw=Maroon")


def test_paste_image(editor, session):
    from PySide6.QtWidgets import QApplication
    QApplication.clipboard().setImage(solid_image("blue"))
    editor.paste()
    new = by_id(editor)["img2"]
    assert new["file"] == "fig_slides/lec-f1-1.png"
    assert os.path.exists(os.path.join(session["tex_dir"], new["file"]))


def test_items_survive_gc(editor):
    """Regression: PySide dropped Python wrappers of items made in callbacks."""
    editor.add_arrow()
    editor.add_text()
    gc.collect()
    assert {"arrow2", "text2"} <= set(by_id(editor))


def test_reload_replaces_elements(editor, session):
    session = dict(session, items=[ITEMS[2]])
    editor.load(session)
    assert editor.ids() == {"ellipse1"}


def test_save_emits_json(editor, capsys):
    editor.save()
    message = json.loads(capsys.readouterr().out.strip())
    assert len(message["items"]) == len(ITEMS)
    assert message["background"] == {"color": "bblue!20", "image": ""}


# ---- frame background --------------------------------------------------------

def test_background_dialog_roundtrip(editor):
    dialog = beamer_gui.BackgroundDialog(editor, editor.frame_background)
    assert dialog.color.currentText() == "bblue" and dialog.tint.value() == 20
    assert dialog.background() == {"color": "bblue!20", "image": ""}
    dialog.color.setCurrentText("none")
    dialog.image.setText("fig_slides/g.png")
    assert dialog.background() == {"color": "", "image": "fig_slides/g.png"}


def test_background_image_from_clipboard_and_file(editor, session, tmp_path_factory):
    from PySide6.QtWidgets import QApplication
    dialog = beamer_gui.BackgroundDialog(editor, {"color": "", "image": ""})
    QApplication.clipboard().setImage(solid_image("red"))
    dialog.paste()
    assert dialog.image.text() == "fig_slides/lec-f1-1.png"
    outside = tmp_path_factory.mktemp("elsewhere") / "photo.png"
    solid_image("blue").save(str(outside))
    assert editor.import_image(str(outside)) == "fig_slides/lec-f1-2.png"
    inside = os.path.join(session["tex_dir"], "fig_slides", "g.png")
    assert editor.import_image(inside) == "fig_slides/g.png"     # not copied
    editor.set_background_spec(dialog.background())
    assert editor.frame_background["image"] == "fig_slides/lec-f1-1.png"


# ---- snapping ------------------------------------------------------------------

def test_snapping_aligns_moved_element(editor):
    el = elements(editor)
    ellipse, rect = el["ellipse1"], el["rect1"]       # rect left edge at x=.7
    editor.scene.clearSelection()
    ellipse.setSelected(True)
    editor.dragging = True
    ellipse.setPos(0.7 * editor.W + 4, ellipse.y())  # 4 px from the rect's left edge
    assert abs(ellipse.x() - rect.x()) < 1e-9
    assert editor.guides[0].isVisible()
    editor.dragging = False
    ellipse.setPos(0.7 * editor.W + 4, ellipse.y())  # not dragging: no snap
    assert abs(ellipse.x() - rect.x() - 4) < 1e-9


def test_snapping_to_page_centre_and_toggle(editor):
    ellipse = elements(editor)["ellipse1"]
    editor.scene.clearSelection()
    ellipse.setSelected(True)
    editor.dragging = True
    w = ellipse.rect().width()
    ellipse.setPos(editor.W / 2 - w / 2 + 3, ellipse.y())   # centre 3 px off
    assert abs(ellipse.x() + w / 2 - editor.W / 2) < 1e-9
    editor.toggle_snapping(False)
    ellipse.setPos(editor.W / 2 - w / 2 + 3, ellipse.y())
    assert abs(ellipse.x() + w / 2 - editor.W / 2 - 3) < 1e-9


def test_snapping_resize_edge(editor):
    el = elements(editor)
    ellipse, rect = el["ellipse1"], el["rect1"]
    editor.scene.clearSelection()
    ellipse.setSelected(True)
    editor.dragging = True
    right = ellipse.x() + ellipse.rect().width()
    drag_handle(ellipse, "e", (rect.x() - right - 5) / editor.W, 0, steps=1)
    assert abs(ellipse.x() + ellipse.rect().width() - rect.x()) < 1e-9


def test_snapping_arrow_end(editor):
    el = elements(editor)
    arrow, rect = el["arrow1"], el["rect1"]
    editor.scene.clearSelection()
    arrow.setSelected(True)
    editor.dragging = True
    target = QPointF(rect.x() + 3, rect.y() - 2)        # near the rect's corner
    arrow.handles[1].setPos(arrow.mapFromScene(target))
    end = arrow.ends[1] + arrow.pos()
    assert abs(end.x() - rect.x()) < 1e-9 and abs(end.y() - rect.y()) < 1e-9


def test_snapping_only_single_selection(editor):
    el = elements(editor)
    for k in ("ellipse1", "img1"):
        el[k].setSelected(True)
    editor.dragging = True
    assert not editor.snap_active(el["ellipse1"])


def test_snapping_with_real_mouse_drag(editor):
    """Press, move and release through the view; guides hide on release."""
    from PySide6.QtCore import QEvent, Qt
    from PySide6.QtGui import QMouseEvent
    from PySide6.QtWidgets import QApplication
    el = elements(editor)
    ellipse, rect = el["ellipse1"], el["rect1"]
    view = editor.view
    editor.show()
    editor.scene.clearSelection()
    ellipse.setSelected(True)

    def send(kind, scene_pt, buttons):
        p = view.mapFromScene(scene_pt)
        QApplication.sendEvent(view.viewport(), QMouseEvent(
            kind, QPointF(p), QPointF(view.viewport().mapToGlobal(p)),
            Qt.LeftButton, buttons, Qt.NoModifier))

    grab = ellipse.mapToScene(ellipse.rect().center())
    target_dx = rect.x() - ellipse.x() + 4          # 4 px right of the rect's left edge
    send(QEvent.MouseButtonPress, grab, Qt.LeftButton)
    for i in range(1, 11):
        send(QEvent.MouseMove, grab + QPointF(target_dx * i / 10, 0), Qt.LeftButton)
    assert abs(ellipse.x() - rect.x()) < 1.0
    assert editor.guides[0].isVisible()
    send(QEvent.MouseButtonRelease, grab + QPointF(target_dx, 0), Qt.NoButton)
    assert not editor.guides[0].isVisible()


# ---- jumping to the source -------------------------------------------------------

def test_ctrl_click_and_double_click_send_goto(editor, capsys):
    from PySide6.QtCore import QEvent, Qt
    from PySide6.QtGui import QMouseEvent
    from PySide6.QtWidgets import QApplication
    editor.page_words = [(0.12, 0.52, 0.2, 0.56, "Blockword")]   # in element c1's box
    view = editor.view
    editor.show()

    def send(kind, scene_pt, modifiers):
        p = view.mapFromScene(scene_pt)
        QApplication.sendEvent(view.viewport(), QMouseEvent(
            kind, QPointF(p), QPointF(view.viewport().mapToGlobal(p)),
            Qt.LeftButton, Qt.LeftButton, modifiers))

    point = QPointF(0.15 * editor.W, 0.54 * editor.H)
    send(QEvent.MouseButtonPress, point, Qt.ControlModifier)
    message = json.loads(capsys.readouterr().out.strip())
    assert message == {"goto": {"word": "Blockword", "raw": "", "nth": 0, "before": [],
                                "after": [], "element": "c1"}}
    send(QEvent.MouseButtonDblClick, point, Qt.NoModifier)
    assert json.loads(capsys.readouterr().out.strip())["goto"]["element"] == "c1"


def test_double_click_on_text_shape_still_edits(editor, capsys, monkeypatch):
    calls = []
    monkeypatch.setattr(beamer_gui.QInputDialog, "getMultiLineText",
                        staticmethod(lambda *a: (calls.append(1), ("new", True))[1]))
    from PySide6.QtCore import QEvent, Qt
    from PySide6.QtGui import QMouseEvent
    from PySide6.QtWidgets import QApplication
    view = editor.view
    editor.show()
    text = elements(editor)["text1"]
    p = view.mapFromScene(text.mapToScene(text.rect().center()))
    QApplication.sendEvent(view.viewport(), QMouseEvent(
        QEvent.MouseButtonDblClick, QPointF(p), QPointF(view.viewport().mapToGlobal(p)),
        Qt.LeftButton, Qt.LeftButton, Qt.NoModifier))
    assert calls and text.text == "new"
    assert capsys.readouterr().out == ""


def test_click_in_moved_element_maps_to_compiled_page(editor):
    c1 = elements(editor)["c1"]                     # box0 (0.1, 0.5, 0.3, 0.2)
    editor.page_words = [(0.12, 0.52, 0.2, 0.56, "Blockword")]
    c1.setPos(c1.x() + 0.3 * editor.W, c1.y())      # moved, not yet saved
    info = editor.click_info(QPointF(0.45 * editor.W, 0.54 * editor.H))
    assert info["word"] == "Blockword" and info["element"] == "c1"


# ---- more styles, external programs, errors ------------------------------------------

def test_style_panel_corners_and_opacity(editor):
    el = elements(editor)
    editor.scene.clearSelection()
    el["rect1"].setSelected(True)
    panel = editor.style_panel
    panel.corners.setValue(6)
    panel.line_opacity.setValue(0.5)
    opts = by_id(editor)["rect1"]["opts"]
    assert "rounded corners=6pt" in opts and "draw opacity=0.5" in opts
    editor.scene.clearSelection()
    el["arrow1"].setSelected(True)
    assert not panel.corners.isEnabled()
    panel.tips.setCurrentText("|-|")
    assert "|-|" in by_id(editor)["arrow1"]["opts"]


def test_edit_image_in_external_program(editor, session, tmp_path, monkeypatch, capsys):
    from PySide6.QtTest import QTest
    program = tmp_path / "bin" / "fakeeditor"
    program.parent.mkdir()
    program.write_text("#!/bin/sh\nexit 0\n")
    program.chmod(0o755)
    monkeypatch.setenv("PATH", f"{program.parent}:{os.environ['PATH']}")
    editor.image_editors = {"png": "fakeeditor"}
    image = elements(editor)["img1"]
    assert image.image_file() == "fig_slides/g.png"
    assert editor.image_command("fig_slides/g.png") == "fakeeditor"
    assert editor.image_command("x.svg") is None
    assert editor.edit_image("fig_slides/g.png")
    path = editor.image_path("fig_slides/g.png")
    assert path in editor.watcher.files()
    capsys.readouterr()
    editor.image_changed(path)            # as when the program saves the file
    QTest.qWait(800)
    assert '"items"' in capsys.readouterr().out
    editor.image_editors = {}
    assert not editor.edit_image("fig_slides/g.png")


def test_error_from_emacs_shown(editor):
    editor.handle_message({"error": "beamer-gui: LaTeX failed: Undefined control sequence."})
    assert "LaTeX failed" in editor.statusBar().currentMessage()
