"""Run with the configured PyMuPDF interpreter."""
import importlib.util
import json
import unittest
from pathlib import Path

import pymupdf

spec = importlib.util.spec_from_file_location(
    "invoice_tables", Path(__file__).resolve().parents[2] / "priv/python/invoice_tables.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EligibilityTest(unittest.TestCase):
    def setUp(self):
        self.doc = pymupdf.open()
        self.page = self.doc.new_page()

    def tearDown(self):
        self.doc.close()

    def test_visible_native_text_is_eligible(self):
        self.page.insert_text((40, 50), "Invoice ABC123 GSTIN 33AEHFS3648M1ZL Amount 10500")
        self.assertIsNone(module.page_reason(self.page))

    def test_hidden_ocr_layer_is_not_eligible(self):
        self.page.insert_text((40, 50), "Invoice ABC123 GSTIN 33AEHFS3648M1ZL Amount 10500", render_mode=3)
        self.assertEqual(module.page_reason(self.page), "hidden_text_layer")

    def test_large_image_with_visible_header_is_not_eligible(self):
        self.page.insert_text((40, 50), "Invoice ABC123 GSTIN 33AEHFS3648M1ZL Amount 10500")
        pix = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 10, 10), False)
        pix.clear_with(255)
        self.page.insert_image(pymupdf.Rect(0, 100, 500, 700), pixmap=pix)
        self.assertEqual(module.page_reason(self.page), "substantial_image_content")

    def test_blank_page_is_not_eligible(self):
        self.assertEqual(module.page_reason(self.page), "insufficient_native_text")

    def test_partial_grid_keeps_tax_and_total_in_the_missing_cell(self):
        # Three bordered cells form an L, leaving bottom-right text outside
        # the cells but inside the detected table's overall bounding box.
        for rect in [(40, 100, 240, 150), (240, 100, 440, 150), (40, 150, 240, 200)]:
            self.page.draw_rect(pymupdf.Rect(rect))
        self.page.insert_text((50, 125), "Description")
        self.page.insert_text((250, 125), "Amount")
        self.page.insert_text((50, 175), "Goods 1000")
        self.page.insert_text((250, 170), "IGST 180")
        self.page.insert_text((250, 190), "Total 1180")

        result = json.loads(module.table_text(self.page))
        self.assertEqual(len(result["tables"]), 1)
        self.assertIn("Goods 1000", str(result["tables"]))
        self.assertIn("IGST 180", result["text_outside_tables"])
        self.assertIn("Total 1180", result["text_outside_tables"])



if __name__ == "__main__":
    unittest.main()
