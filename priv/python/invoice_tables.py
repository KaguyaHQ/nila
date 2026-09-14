"""Native invoice tables. Never OCR a page or trust an invisible OCR layer."""
import json
import sys
from pathlib import Path

import pymupdf


def page_reason(page):
    traces = page.get_texttrace()
    if any(s.get("type") == 3 or s.get("opacity", 1) == 0 for s in traces):
        return "hidden_text_layer"
    visible = sum(len(s["chars"]) for s in traces if s.get("type") != 3)
    if visible < 40:
        return "insufficient_native_text"
    # Logos are harmless; large or tiled raster regions may contain invoice facts
    # omitted from native text. Prefer the complete image for those pages.
    image_area = sum((pymupdf.Rect(i["bbox"]) & page.rect).get_area()
                     for i in page.get_image_info())
    if image_area > page.rect.get_area() * 0.20:
        return "substantial_image_content"
    return None


def table_text(page):
    # Keep Layout off: with PyMuPDF/Layout 1.28.2, Simple Systems invoice 53
    # split 4810.50 into "481050\n." when enabled. 4LLM Markdown also broke
    # its GSTIN and decimals. Recheck this bill before enabling either path.
    tables = page.find_tables(strategy="lines", use_layout=False).tables
    # A partial grid can have gaps inside its overall bounding box. Only text
    # covered by an actual cell is represented in the extracted table rows.
    bounds = [cell for table in tables for cell in table.cells if cell is not None]
    groups = {}
    for word in page.get_text("words", sort=True):
        x, y = (word[0] + word[2]) / 2, (word[1] + word[3]) / 2
        if any(box[0] <= x <= box[2] and box[1] <= y <= box[3] for box in bounds):
            continue
        groups.setdefault((word[5], word[6]), []).append(word)
    lines = sorted(groups.values(), key=lambda ws: (min(w[1] for w in ws), min(w[0] for w in ws)))
    text = "\n".join(" ".join(w[4] for w in sorted(ws, key=lambda w: w[0])) for ws in lines)
    return json.dumps({"text_outside_tables": text,
                       "tables": [{"rows": table.extract()} for table in tables]},
                      ensure_ascii=False, indent=2)


def extract(source):
    with pymupdf.open(source) as doc:
        if len(doc) > 100:
            raise ValueError("too_many_pages")
        pages = []
        for index, page in enumerate(doc):
            reason = page_reason(page)
            text = ""
            if reason is None:
                try:
                    text = table_text(page)
                except Exception:
                    reason = "table_conversion_failed"
            pages.append({"page": index + 1, "text": text if reason is None else "",
                          "fallback_reason": reason})
        return {"pages": pages}


if __name__ == "__main__":
    result = json.dumps(extract(sys.argv[1]), ensure_ascii=False)
    if len(result.encode("utf-8")) > 2_000_000:
        raise ValueError("native_tables_too_large")
    Path(sys.argv[2]).write_text(result, encoding="utf-8")
