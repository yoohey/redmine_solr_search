"""Generate the sample attachments in files/ from lines.yml, and write manifest.yml (which file is which line).

One file per JR line, listing its stations. Formats are assigned at random (fixed seed) so that every format below
appears at least once. The files are committed; re-run this only when lines.yml or the formats change:

    python3 -m venv /tmp/venv && /tmp/venv/bin/pip install python-docx openpyxl python-pptx reportlab pillow pyyaml
    /tmp/venv/bin/python generate.py      # then re-run seed/expect.sh: the manifest contents feed the expectations

Formats, and whether the text can be extracted (for Tika later):
    txt, md, csv, json, xml, html      plain text (UTF-8)
    txt-sjis, csv-sjis                 plain text in Shift_JIS (common for files made on Windows in Japan)
    pdf, docx, xlsx, pptx              binary documents with a text layer
    zip                                an archive holding a .txt and a .csv
    png, pdf-image                     images only: no text layer, findable by file name only
PNG rendering needs a Japanese font; the macOS Hiragino font is used (the PDF uses a built-in Japanese CID font).
"""

import csv
import datetime
import io
import json
import random
import re
import shutil
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

import yaml
from docx import Document
from openpyxl import Workbook
from PIL import Image, ImageDraw, ImageFont
from pptx import Presentation
from pptx.util import Pt
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas

HERE = Path(__file__).resolve().parent
OUT = HERE / "files"
FONT_PNG = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
FIXED_TIME = datetime.datetime(2026, 1, 1, 9, 0, 0)  # keeps Office metadata stable between runs

EXTENSIONS = {"txt": "txt", "txt-sjis": "txt", "md": "md", "csv": "csv", "csv-sjis": "csv", "json": "json",
              "xml": "xml", "html": "html", "pdf": "pdf", "docx": "docx", "xlsx": "xlsx", "pptx": "pptx",
              "zip": "zip", "png": "png", "pdf-image": "pdf"}
NO_TEXT = {"png", "pdf-image"}
EXTRA = ["pdf", "docx", "xlsx", "pptx"]  # formats used again once every format has been used


def title(line):
    return line["name"] if line.get("secret") else f"JR{line['name']} 駅一覧"


def summary(line):
    s = line["stations"]
    return f"全{len(s)}駅（{s[0]}〜{s[-1]}）"


def as_text(line):
    lines = [title(line), summary(line), ""]
    if line.get("secret"):
        lines[1:1] = ["社外秘：関係者以外に共有しないこと。駅名はすべて仮称。"]
    lines += [f"{i}. {name}" for i, name in enumerate(line["stations"], 1)]
    return "\n".join(lines) + "\n"


def as_csv(line):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\r\n")
    w.writerow(["路線", "順番", "駅名"])
    for i, name in enumerate(line["stations"], 1):
        w.writerow([line["name"], i, name])
    return buf.getvalue()


# Every writer returns the text a correct extractor should find in the file ("" when there is none). It goes to
# manifest.yml as `content`, which the search expectations are computed from.

def write_txt(line, path, encoding="utf-8"):
    path.write_bytes(as_text(line).encode(encoding))
    return as_text(line)


def write_csv(line, path, encoding="utf-8"):
    path.write_bytes(as_csv(line).encode(encoding))
    return as_csv(line)


def write_md(line, path):
    body = [f"# {title(line)}", "", summary(line), "", "| 順番 | 駅名 |", "|---:|---|"]
    body += [f"| {i} | {name} |" for i, name in enumerate(line["stations"], 1)]
    text = "\n".join(body) + "\n"
    path.write_text(text, encoding="utf-8")
    return text


def write_json(line, path):
    data = {"line": line["name"], "stations": [{"order": i, "name": n} for i, n in enumerate(line["stations"], 1)]}
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text, encoding="utf-8")
    return text


def write_xml(line, path):
    rows = [f'  <station order="{i}">{escape(n)}</station>' for i, n in enumerate(line["stations"], 1)]
    xml = f'<?xml version="1.0" encoding="UTF-8"?>\n<line name="{escape(line["name"])}">\n' + "\n".join(rows) + "\n</line>\n"
    path.write_text(xml, encoding="utf-8")
    return xml


def write_html(line, path):
    items = "\n".join(f"    <li>{escape(n)}</li>" for n in line["stations"])
    html = (f'<!DOCTYPE html>\n<html lang="ja">\n<head><meta charset="utf-8"><title>{escape(title(line))}</title></head>\n'
            f"<body>\n  <h1>{escape(title(line))}</h1>\n  <p>{escape(summary(line))}</p>\n  <ol>\n{items}\n  </ol>\n</body>\n</html>\n")
    path.write_text(html, encoding="utf-8")
    return "\n".join([title(line), summary(line), *line["stations"]]) + "\n"  # the visible text, without tags


def write_pdf(line, path):
    pdfmetrics.registerFont(UnicodeCIDFont("HeiseiKakuGo-W5"))
    c = canvas.Canvas(str(path), pagesize=A4, invariant=1)
    c.setTitle(title(line))
    _, height = A4
    y = height - 60
    texts = [title(line), summary(line)] + [f"{i}. {n}" for i, n in enumerate(line["stations"], 1)]
    c.setFont("HeiseiKakuGo-W5", 16)
    c.drawString(50, y, title(line))
    c.setFont("HeiseiKakuGo-W5", 10)
    y -= 22
    c.drawString(50, y, summary(line))
    y -= 26
    for i, name in enumerate(line["stations"], 1):
        if y < 60:
            c.showPage()
            c.setFont("HeiseiKakuGo-W5", 10)
            y = height - 60
        c.drawString(60, y, f"{i}. {name}")
        y -= 16
    c.save()
    return "\n".join(texts) + "\n"


def write_docx(line, path):
    doc = Document()
    doc.core_properties.created = doc.core_properties.modified = FIXED_TIME
    doc.core_properties.title = title(line)
    texts = [title(line)] + (["社外秘：関係者以外に共有しないこと。駅名はすべて仮称。"] if line.get("secret") else [])
    texts += [summary(line), "順番", "駅名"]
    for t in texts[:-2]:
        doc.add_heading(t, level=1) if t == title(line) else doc.add_paragraph(t)
    table = doc.add_table(rows=1, cols=2)
    table.style = "Table Grid"
    table.rows[0].cells[0].text, table.rows[0].cells[1].text = "順番", "駅名"
    for i, name in enumerate(line["stations"], 1):
        cells = table.add_row().cells
        cells[0].text, cells[1].text = str(i), name
        texts += [str(i), name]
    doc.save(path)
    return "\n".join(texts) + "\n"


def write_xlsx(line, path):
    wb = Workbook()
    wb.properties.created = wb.properties.modified = FIXED_TIME
    ws = wb.active
    ws.title = "駅一覧"
    rows = [["路線", "順番", "駅名"]] + [[line["name"], i, name] for i, name in enumerate(line["stations"], 1)]
    for row in rows:
        ws.append(row)
    ws.column_dimensions["A"].width = 24
    ws.column_dimensions["C"].width = 20
    wb.save(path)
    return "\n".join("\t".join(str(v) for v in row) for row in rows) + "\n"


def write_pptx(line, path):
    prs = Presentation()
    prs.core_properties.created = prs.core_properties.modified = FIXED_TIME
    cover = prs.slides.add_slide(prs.slide_layouts[0])
    cover.shapes.title.text = title(line)
    cover.placeholders[1].text = summary(line)
    texts = [title(line), summary(line)]
    stations = line["stations"]
    for start in range(0, len(stations), 12):
        slide = prs.slides.add_slide(prs.slide_layouts[1])
        slide.shapes.title.text = f"{line['name']}（{start + 1}〜{min(start + 12, len(stations))}駅目）"
        texts.append(slide.shapes.title.text)
        body = slide.placeholders[1].text_frame
        for j, name in enumerate(stations[start:start + 12]):
            p = body.paragraphs[0] if j == 0 else body.add_paragraph()
            p.text = f"{start + j + 1}. {name}"
            p.font.size = Pt(16)
            texts.append(p.text)
    prs.save(path)
    return "\n".join(texts) + "\n"


def write_zip(line, path):
    entries = [(f"{line['name']}.txt", as_text(line)), (f"{line['name']}.csv", as_csv(line))]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=FIXED_TIME.timetuple()[:6])
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data.encode("utf-8"))
    return "".join(data for _, data in entries)


def render_image(line):
    font_title = ImageFont.truetype(FONT_PNG, 36)
    font = ImageFont.truetype(FONT_PNG, 24)
    stations = line["stations"]
    per_col = 16
    cols = (len(stations) + per_col - 1) // per_col
    img = Image.new("RGB", (80 + cols * 300, 160 + min(len(stations), per_col) * 36), "white")
    d = ImageDraw.Draw(img)
    d.text((40, 30), title(line), font=font_title, fill="black")
    d.text((40, 80), summary(line), font=font, fill="dimgray")
    for i, name in enumerate(stations):
        col, row = divmod(i, per_col)
        d.text((40 + col * 300, 130 + row * 36), f"{i + 1}. {name}", font=font, fill="black")
    return img


def write_png(line, path):
    render_image(line).save(path, optimize=True)
    return ""


def write_pdf_image(line, path):
    # Like a scanned document: the page is one picture, there is no text to extract
    render_image(line).save(path, "PDF", resolution=100.0, creationDate=FIXED_TIME.timetuple(), modDate=FIXED_TIME.timetuple())
    return ""


def fix_zip_times(path):
    """docx/xlsx/pptx are zip files whose entries carry the current time: rewrite them with FIXED_TIME."""
    stamp = FIXED_TIME.strftime("%Y-%m-%dT%H:%M:%SZ").encode()
    with zipfile.ZipFile(path) as z:
        entries = [(info, z.read(info)) for info in z.infolist()]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for info, data in entries:
            if info.filename == "docProps/core.xml":  # openpyxl stamps the save time here whatever we set
                data = re.sub(rb"(<dcterms:(?:created|modified)[^>]*>)[^<]*", rb"\g<1>" + stamp, data)
            fixed = zipfile.ZipInfo(info.filename, date_time=FIXED_TIME.timetuple()[:6])
            fixed.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(fixed, data)


class LiteralDumper(yaml.SafeDumper):
    """Writes multi-line strings as `|` blocks, so manifest.yml stays readable."""


LiteralDumper.add_representer(
    str, lambda d, v: d.represent_scalar("tag:yaml.org,2002:str", v, style="|" if "\n" in v else None))


WRITERS = {
    "txt": write_txt, "txt-sjis": lambda l, p: write_txt(l, p, "cp932"), "md": write_md, "csv": write_csv,
    "csv-sjis": lambda l, p: write_csv(l, p, "cp932"), "json": write_json, "xml": write_xml, "html": write_html,
    "pdf": write_pdf, "docx": write_docx, "xlsx": write_xlsx, "pptx": write_pptx, "zip": write_zip,
    "png": write_png, "pdf-image": write_pdf_image,
}


def main():
    lines = yaml.safe_load((HERE / "lines.yml").read_text(encoding="utf-8"))
    public = [l for l in lines if not l.get("secret")]
    rng = random.Random(42)

    formats = list(WRITERS)
    rng.shuffle(formats)
    formats += [rng.choice(EXTRA) for _ in range(len(public) - len(formats))]

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()

    manifest = []
    for line, fmt in list(zip(public, formats)) + [(l, "docx") for l in lines if l.get("secret")]:
        stem = f"社外秘_{line['name']}" if line.get("secret") else f"JR{line['name']}_駅一覧"
        suffix = "_スキャン" if fmt == "pdf-image" else ""
        filename = f"{stem}{suffix}.{EXTENSIONS[fmt]}"
        content = WRITERS[fmt](line, OUT / filename)
        if fmt in ("docx", "xlsx", "pptx"):
            fix_zip_times(OUT / filename)
        manifest.append({"file": filename, "line": line["id"], "format": fmt, "text": fmt not in NO_TEXT,
                         "secret": bool(line.get("secret")), "content": content})

    header = ("# Generated by generate.py -- do not edit. One entry per file in files/.\n"
              "#   text: false = image only, no text to extract (findable by file name only)\n"
              "#   secret: true = attach to private issues only\n"
              "#   content: the text a correct extractor finds in the file (the search expectations match against it)\n")
    (HERE / "manifest.yml").write_text(header + yaml.dump(manifest, Dumper=LiteralDumper, allow_unicode=True, sort_keys=False, width=200),
                                       encoding="utf-8")
    for m in manifest:
        print(f"{m['format']:10} {m['file']}")


if __name__ == "__main__":
    main()
