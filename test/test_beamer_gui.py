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


# ---- core -----------------------------------------------------------------

def test_unique_image_path(tmp_path):
    first = core.unique_image_path(str(tmp_path), "lec-f3")
    assert first.endswith("lec-f3-1.png")
    open(first, "w").close()
    assert core.unique_image_path(str(tmp_path), "lec-f3").endswith("lec-f3-2.png")
    assert core.unique_image_path(str(tmp_path), "lec-f3", ".pdf").endswith("lec-f3-1.pdf")


def test_rel_to_tex(tmp_path):
    path = os.path.join(str(tmp_path), "fig_slides", "a.png")
    assert core.rel_to_tex(path, str(tmp_path)) == "fig_slides/a.png"


def test_resolve_image(tmp_path):
    os.makedirs(tmp_path / "fig_slides")
    (tmp_path / "fig_slides" / "x.pdf").write_text("")
    tex = str(tmp_path)
    assert core.resolve_image("fig_slides/x", tex).endswith("x.pdf")
    assert core.resolve_image("fig_slides/y.png", tex).endswith("y.png")
    assert core.resolve_image("/abs/z.png", tex) == "/abs/z.png"


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


def test_new_id():
    assert core.new_id("img", set()) == "img1"
    assert core.new_id("img", {"img1", "img2"}) == "img3"


def test_to_frac_clamps_and_rounds():
    assert core.to_frac(600, 1200) == 0.5
    assert core.to_frac(1 / 3 * 1200, 1200) == 0.3333
    assert core.to_frac(-5000, 1200) == -0.5
    assert core.to_frac(5000, 1200) == 1.5


def test_is_image_file_and_safe_stem():
    assert core.is_image_file("a.PNG") and core.is_image_file("b.pdf")
    assert not core.is_image_file("c.txt")
    assert core.safe_stem("my lec/f1") == "my-lec-f1"
    assert core.safe_stem("///") == "img"


# ---- offscreen GUI --------------------------------------------------------

pytest.importorskip("PySide6")

ITEMS = [
    {"kind": "image", "id": "img1", "file": "fig_slides/g.png", "x": 0.1, "y": 0.2, "w": 0.3},
    {"kind": "arrow", "id": "arrow1", "x1": 0.6, "y1": 0.2, "x2": 0.2, "y2": 0.7},
    {"kind": "ellipse", "id": "ellipse1", "x": 0.4, "y": 0.4, "w": 0.2, "h": 0.1},
    {"kind": "raw", "id": "t1", "x": 0.5, "y": 0.5, "w": 0.3, "body": "$x$"},
]


@pytest.fixture(scope="module")
def app():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtWidgets import QApplication
    return QApplication.instance() or QApplication([])


def solid_image(color, w=40, h=40):
    from PySide6.QtGui import QColor, QImage
    img = QImage(w, h, QImage.Format_RGB32)
    img.fill(QColor(color))
    return img


def copy_to_clipboard(img):
    from PySide6.QtWidgets import QApplication
    QApplication.clipboard().setImage(img)


@pytest.fixture
def session(app, tmp_path):
    if not shutil.which("pdflatex"):
        pytest.skip("pdflatex missing")
    (tmp_path / "bg.tex").write_text(
        "\\documentclass{beamer}\\begin{document}\\begin{frame}x\\end{frame}\\end{document}")
    subprocess.run(["pdflatex", "-interaction=nonstopmode", "bg.tex"], cwd=tmp_path,
                   check=True, stdout=subprocess.DEVNULL)
    os.makedirs(tmp_path / "fig_slides")
    solid_image("green", 100, 50).save(str(tmp_path / "fig_slides" / "g.png"))
    return {"background": str(tmp_path / "bg.pdf"), "tex_dir": str(tmp_path),
            "image_dir": str(tmp_path / "fig_slides"), "stem": "lec-f1",
            "items": [dict(i) for i in ITEMS]}


@pytest.fixture
def editor(session):
    import beamer_gui
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
        for key, value in item.items():
            if isinstance(value, float):
                assert_close(out[item["id"]], **{key: value})
            else:
                assert out[item["id"]][key] == value


def test_move_and_resize(editor):
    from PySide6.QtCore import QPointF
    el, W, H = elements(editor), editor.W, editor.H
    el["img1"].setPos(0.5 * W, 0.5 * H)
    el["ellipse1"].handle.setPos(QPointF(0.3 * W, 0.2 * H))      # resize handle
    el["arrow1"].handles[1].setPos(QPointF(0.1 * W, 0.1 * H))    # arrow tip
    out = by_id(editor)
    assert out["img1"]["x"] == 0.5 and out["img1"]["y"] == 0.5
    assert_close(out["ellipse1"], w=0.3, h=0.2)
    assert_close(out["arrow1"], x2=0.1, y2=0.1)
    el["arrow1"].setPos(0.1 * W, 0.1 * H)                         # whole arrow
    assert_close(by_id(editor)["arrow1"], x1=0.7, y1=0.3, x2=0.2, y2=0.2)


def test_add_delete_and_stacking_order(editor):
    editor.add_arrow()
    editor.add_ellipse()
    elements(editor)["t1"].setSelected(True)
    editor.delete()
    # Source order, then additions on top, as LaTeX draws later blocks on top.
    assert [d["id"] for d in editor.items_dicts()] == [
        "img1", "arrow1", "ellipse1", "arrow2", "ellipse2"]


def test_paste_image(editor, session):
    copy_to_clipboard(solid_image("blue"))
    editor.paste()
    new = by_id(editor)["img2"]
    assert new["file"] == "fig_slides/lec-f1-1.png"
    assert os.path.exists(os.path.join(session["tex_dir"], new["file"]))


def test_items_survive_gc(editor):
    """Regression: PySide dropped Python wrappers of items made in callbacks."""
    copy_to_clipboard(solid_image("red"))
    editor.paste()
    editor.add_arrow()
    gc.collect()
    assert {"img2", "arrow2"} <= set(by_id(editor))


def test_save_emits_json(editor, capsys):
    editor.save()
    message = json.loads(capsys.readouterr().out.strip())
    assert len(message["items"]) == len(ITEMS)
