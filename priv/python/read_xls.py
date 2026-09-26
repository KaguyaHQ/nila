"""Read legacy BIFF8 cells only. No formula evaluation or business interpretation."""
import io
import json
import math
import struct
import sys


def read(path):
    import xlrd
    from xlrd.compdoc import CompDoc

    with open(path, "rb") as source:
        data = source.read(5_000_001)
    if len(data) > 5_000_000:
        raise ValueError("too_large")
    if not data.startswith(bytes.fromhex("D0CF11E0A1B11AE1")):
        raise ValueError("invalid_file")
    # xlrd exposes cached formula results as ordinary values. Reject formula
    # records before reading cells so stale caches cannot become tax facts.
    compound = CompDoc(data, logfile=io.StringIO())
    stream = compound.get_named_stream("Workbook")
    if stream is None:
        raise ValueError("invalid_file")
    pos = 0
    while pos + 4 <= len(stream):
        opcode, size = struct.unpack_from("<HH", stream, pos)
        if pos + 4 + size > len(stream):
            raise ValueError("invalid_file")
        if opcode in (0x0006, 0x0206, 0x0406):
            raise ValueError("formula_cells")
        pos += size + 4

    book = xlrd.open_workbook(file_contents=data, on_demand=True, logfile=io.StringIO())
    try:
        if book.biff_version != 80:
            raise ValueError("invalid_file")
        if book.nsheets > 20:
            raise ValueError("too_large")
        sheets = []
        for sheet in book.sheets():
            if sheet.nrows > 5001 or sheet.ncols > 100:
                raise ValueError("too_large")
            rows = []
            for r in range(sheet.nrows):
                cells = {}
                for c in range(sheet.ncols):
                    cell = sheet.cell(r, c)
                    if cell.ctype in (xlrd.XL_CELL_EMPTY, xlrd.XL_CELL_BLANK):
                        continue
                    if cell.ctype in (xlrd.XL_CELL_ERROR, xlrd.XL_CELL_BOOLEAN):
                        raise ValueError("invalid_cell")
                    value = cell.value
                    if cell.ctype == xlrd.XL_CELL_DATE:
                        value = xlrd.xldate_as_datetime(value, book.datemode).date().isoformat()
                    elif cell.ctype == xlrd.XL_CELL_NUMBER:
                        if not math.isfinite(value):
                            raise ValueError("invalid_cell")
                        value = str(int(value)) if value.is_integer() else str(value)
                    cells[xlrd.formula.colname(c)] = str(value).strip()
                if any(cells.values()):
                    rows.append({"row": r + 1, "cells": cells})
            sheets.append({"name": sheet.name, "hidden": sheet.visibility != 0, "rows": rows})
        return {"sheets": sheets, "date1904": bool(book.datemode)}
    finally:
        book.release_resources()


if __name__ == "__main__":
    try:
        result = read(sys.argv[1])
    except ImportError:
        result = {"error": "reader_unavailable"}
    except ValueError as error:
        result = {"error": str(error) if str(error) in {
            "too_large", "invalid_file", "formula_cells", "invalid_cell"
        } else "invalid_file"}
    except Exception:
        result = {"error": "invalid_file"}
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))
