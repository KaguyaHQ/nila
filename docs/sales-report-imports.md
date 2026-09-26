# Sales report imports

Nila maintains report definitions. Accountant staff upload the client's files;
they do not configure columns or grouping rules.

## Current boundary

- `Workbook` and `CsvWorkbook` decode files.
- `TablePlan` describes recognized headers and the table kind. `TableReader`
  locates and binds those headers, preserves cell coordinates, and checks that
  repeated document fields agree. Plans carry an ID and version.
- `StandardSections` combines these plans with explicit Elixir functions for
  section meaning. Invoice rate rows and supplied monthly summaries remain
  different facts.
- `ReportPacket` accepts complementary standard section files as one import.
  It rejects overlapping populated sections and keeps source filenames.
- `ReturnReport`, `ReportImport`, and `ReturnSources` feed the existing month,
  review, workings, and JSON pipeline. Each source row remains available.

DPL, ULTINO, and KPN readers coexist with the shared table reader. Move their
operations into shared code when doing so removes real duplication. There is
no general expression language, automatic AI plan approval, or mapping UI.

## Adding a format

Use a plan for different headings with existing table behavior. Add a shared
operation for repeated behavior that needs new code. Keep unusual layout logic
in a named reader function with the same source-backed output contract.

Verify document identities, rate components, repeated totals, summary roles,
and source coverage. A balanced grand total alone does not prove extraction.
An imported file or downloadable working does not establish JSON readiness.

One section packet is active per client month. Upload its complementary files
together. Removing the report removes its whole contribution from the month;
the original files remain retained in upload history.
