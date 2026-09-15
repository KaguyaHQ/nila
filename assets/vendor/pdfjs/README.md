PDF.js 6.3.289 from the pdfjs-dist npm package (Mozilla, Apache-2.0).
The worker is exported as a string for a module Blob worker, keeping the existing app bundle/build contract.
The invoice viewer renders original PDFs with a selectable text layer; saved page images are used if a PDF cannot be rendered.

text_layer.css contains the text-selection geometry adapted from this version of Mozilla's pdf_viewer.css, scoped to the viewer and using Nila's selection color. It stays beside the library because PDF.js writes these CSS variables directly.
