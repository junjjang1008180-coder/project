"""종이 키보드 템플릿 생성기.

하나의 레이아웃 정의에서 두 가지 결과물을 만든다.
  - Layouts/pk1-qwerty-a4.json : 앱이 인식할 때 쓰는 기준 템플릿 (좌표 단위 mm, 원점 좌상단)
  - Layouts/pk1-qwerty-a4.pdf  : 인쇄용 종이 키보드

인쇄물과 인식 기준이 항상 같은 정의에서 나오므로 서로 어긋나지 않는다.

사용법:
    pip install reportlab segno
    python tools/paper_template.py
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import segno
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Layouts"
BASENAME = "pk1-qwerty-a4"

LAYOUT_ID = "PK1"
PAPER_W, PAPER_H = 297.0, 210.0  # A4 가로

# QR 마커: 심볼 한 변(여백 제외) 26mm. 버전 1(21x21 모듈) → 모듈 약 1.24mm.
# 손이 아래쪽 마커를 가려도 버틸 수 있게 위 3개 + 아래 3개를 둔다 (4개 이상 보이면 보정 가능).
MARKER_SIZE = 26.0
MARKER_QUIET_MODULES = 4
MARKERS = [
    ("TL", 24.0, 24.0),
    ("TC", PAPER_W / 2, 24.0),
    ("TR", PAPER_W - 24.0, 24.0),
    ("BL", 24.0, PAPER_H - 24.0),
    ("BC", PAPER_W / 2, PAPER_H - 24.0),
    ("BR", PAPER_W - 24.0, PAPER_H - 24.0),
]

# 키 배열. 단위 U = 23mm 피치, 키 사이 간격 2mm.
UNIT = 23.0
GAP = 2.0

HANGUL = {
    "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
    "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
    "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
}
NUMBER_SHIFT = dict(zip("1234567890", "!@#$%^&*()"))
PUNCT_SHIFT = {",": "<", ".": ">", "/": "?"}
PUNCT_ID = {",": "comma", ".": "period", "/": "slash"}


def char_key(ch: str) -> dict:
    if ch.isalpha():
        return {"id": ch, "label": ch.upper(), "alt": HANGUL.get(ch),
                "action": {"type": "char", "value": ch, "shift": ch.upper()}}
    if ch.isdigit():
        return {"id": f"digit{ch}", "label": ch, "alt": NUMBER_SHIFT[ch],
                "action": {"type": "char", "value": ch, "shift": NUMBER_SHIFT[ch]}}
    return {"id": PUNCT_ID[ch], "label": ch, "alt": PUNCT_SHIFT[ch],
            "action": {"type": "char", "value": ch, "shift": PUNCT_SHIFT[ch]}}


def special(key_id: str, label: str, action: str) -> dict:
    return {"id": key_id, "label": label, "alt": None, "action": {"type": action}}


# 각 행: (시작 오프셋[U], [(키, 폭[U]), ...])
ROWS = [
    (0.0, [(char_key(c), 1.0) for c in "1234567890"] + [(special("backspace", "Backspace", "backspace"), 1.5)]),
    (0.5, [(char_key(c), 1.0) for c in "qwertyuiop"]),
    (0.75, [(char_key(c), 1.0) for c in "asdfghjkl"] + [(special("enter", "Enter", "enter"), 1.75)]),
    (0.0, [(special("shift", "Shift", "shift"), 1.25)] + [(char_key(c), 1.0) for c in "zxcvbnm,./"]),
    (1.25, [(special("lang", "한/영", "languageToggle"), 1.5), (special("space", "Space", "space"), 6.5)]),
]


def build_layout() -> dict:
    row_units = max(off + sum(w for _, w in keys) for off, keys in ROWS)
    block_w = row_units * UNIT
    block_h = len(ROWS) * UNIT
    x0 = (PAPER_W - block_w) / 2
    # 위/아래 마커(여백 포함) 사이의 세로 공간 한가운데에 키 블록을 둔다.
    quiet = MARKER_SIZE / 21 * MARKER_QUIET_MODULES
    top_limit = 24.0 + MARKER_SIZE / 2 + quiet
    bottom_limit = PAPER_H - 24.0 - MARKER_SIZE / 2 - quiet
    y0 = top_limit + (bottom_limit - top_limit - block_h) / 2
    assert y0 >= top_limit and y0 + block_h <= bottom_limit, "키 블록이 마커 여백과 겹침"

    keys = []
    for r, (offset, row) in enumerate(ROWS):
        x = x0 + offset * UNIT
        y = y0 + r * UNIT
        for key, width in row:
            w = width * UNIT
            rect = [x + GAP / 2, y + GAP / 2, w - GAP, UNIT - GAP]
            k = dict(key)
            k["rect"] = [round(v, 2) for v in rect]
            if k.get("alt") is None:
                k.pop("alt", None)
            keys.append(k)
            x += w

    return {
        "id": LAYOUT_ID,
        "name": "QWERTY · A4 가로",
        "version": 1,
        "paper": {"width": PAPER_W, "height": PAPER_H},
        "markers": [
            {"id": f"{LAYOUT_ID}-{name}", "center": [round(cx, 2), round(cy, 2)], "size": MARKER_SIZE}
            for name, cx, cy in MARKERS
        ],
        "keys": keys,
    }


def register_fonts() -> tuple[str, str]:
    """한글 라벨용 글꼴. Windows의 맑은 고딕을 쓰고, 없으면 Helvetica(한글 생략)."""
    candidates = [
        (os.environ.get("PK_FONT"), os.environ.get("PK_FONT_BOLD")),
        (r"C:\Windows\Fonts\malgun.ttf", r"C:\Windows\Fonts\malgunbd.ttf"),
        ("/System/Library/Fonts/AppleSDGothicNeo.ttc", None),
    ]
    for regular, bold in candidates:
        if regular and Path(regular).exists():
            pdfmetrics.registerFont(TTFont("PKRegular", regular))
            if bold and Path(bold).exists():
                pdfmetrics.registerFont(TTFont("PKBold", bold))
                return "PKRegular", "PKBold"
            return "PKRegular", "PKRegular"
    print("경고: 한글 글꼴을 찾지 못해 Helvetica를 씁니다 (한글 라벨이 깨질 수 있음). PK_FONT 환경변수로 지정하세요.",
          file=sys.stderr)
    return "Helvetica", "Helvetica-Bold"


def render_pdf(layout: dict, path: Path) -> None:
    regular, bold = register_fonts()
    page_w, page_h = landscape(A4)
    c = canvas.Canvas(str(path), pagesize=(page_w, page_h))
    c.setTitle(f"Paper Keyboard {layout['id']}")

    def to_pdf(x_mm: float, y_mm: float) -> tuple[float, float]:
        # 템플릿은 좌상단 원점/아래로 증가, PDF는 좌하단 원점/위로 증가.
        return x_mm * mm, page_h - y_mm * mm

    # QR 마커
    for marker in layout["markers"]:
        qr = segno.make_qr(marker["id"], error="m", version=1)
        matrix = qr.matrix
        modules = len(matrix)
        size = marker["size"]
        cell = size / modules
        left = marker["center"][0] - size / 2
        top = marker["center"][1] - size / 2
        c.setFillGray(0)
        for row_i, row in enumerate(matrix):
            for col_i, dark in enumerate(row):
                if dark:
                    x, y = to_pdf(left + col_i * cell, top + (row_i + 1) * cell)
                    # 인접 모듈 사이에 흰 틈이 생기지 않도록 아주 약간 겹쳐 그린다.
                    c.rect(x, y, cell * mm + 0.05, cell * mm + 0.05, stroke=0, fill=1)

    # 키
    for key in layout["keys"]:
        x, y, w, h = key["rect"]
        px, py = to_pdf(x, y + h)
        c.setStrokeGray(0.35)
        c.setLineWidth(1.0)
        c.setFillGray(1)
        c.roundRect(px, py, w * mm, h * mm, 2.5 * mm, stroke=1, fill=0)

        label = key["label"]
        is_char = key["action"]["type"] == "char"
        c.setFillGray(0)
        if is_char:
            c.setFont(bold, 20)
            lx, ly = to_pdf(x + 3.2, y + 9.5)
            c.drawString(lx, ly, label)
        else:
            c.setFont(bold, 13)
            lx, ly = to_pdf(x + w / 2, y + h / 2 + 1.6)
            c.drawCentredString(lx, ly, label)

        alt = key.get("alt")
        if alt:
            c.setFillGray(0.45)
            c.setFont(regular, 13)
            ax, ay = to_pdf(x + w - 3.2, y + h - 3.0)
            c.drawRightString(ax, ay, alt)

    # 안내 문구: 왼쪽 아래 마커와 가운데 아래 마커 사이, 두 QR의 여백(quiet zone) 밖에만 쓴다.
    quiet = MARKER_SIZE / 21 * MARKER_QUIET_MODULES
    markers = {m["id"].split("-")[-1]: m["center"] for m in layout["markers"]}
    text_left = markers["BL"][0] + MARKER_SIZE / 2 + quiet + 2
    text_right = markers["BC"][0] - MARKER_SIZE / 2 - quiet - 2
    lines = [
        (bold, 10, f"Paper Keyboard · {layout['id']} · QWERTY"),
        (regular, 8.5, "QR 6개 중 4개 이상이 보이게 두세요."),
        (regular, 8.5, "인쇄 배율은 무관, 가로세로 비율만 유지."),
    ]
    c.setFillGray(0.4)
    baseline = markers["BL"][1] - 3.5
    for font, size, text in lines:
        width_mm = pdfmetrics.stringWidth(text, font, size) / mm
        assert text_left + width_mm <= text_right, f"안내 문구가 QR 여백을 침범: {text!r}"
        c.setFont(font, size)
        tx, ty = to_pdf(text_left, baseline)
        c.drawString(tx, ty, text)
        baseline += 4.6

    c.showPage()
    c.save()


def main() -> None:
    layout = build_layout()
    OUT_DIR.mkdir(exist_ok=True)
    json_path = OUT_DIR / f"{BASENAME}.json"
    pdf_path = OUT_DIR / f"{BASENAME}.pdf"
    json_path.write_text(json.dumps(layout, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    render_pdf(layout, pdf_path)
    print(f"키 {len(layout['keys'])}개, 마커 {len(layout['markers'])}개")
    print(f"→ {json_path.relative_to(ROOT)}")
    print(f"→ {pdf_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
