import { useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowLeft, ArrowRight, FileText, Upload, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { monthLabel } from "@/data/sales";
import { useUploadPreview } from "@/state/upload-preview";

function fileSize(bytes: number) {
  return bytes < 1024 * 1024
    ? `${Math.max(1, Math.ceil(bytes / 1024))} KB`
    : `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export default function SalesUpload() {
  const { files, addFiles, removeFile, clearFiles } = useUploadPreview();
  const picker = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const [errors, setErrors] = useState<string[]>([]);

  function selectFiles(incoming: File[]) {
    const accepted: File[] = [];
    const rejected: string[] = [];
    for (const file of incoming) {
      if (!/\.pdf$/i.test(file.name) || (file.type && file.type !== "application/pdf")) {
        rejected.push(`${file.name}: choose a PDF file.`);
      } else if (file.size === 0) {
        rejected.push(`${file.name}: this file is empty.`);
      } else {
        accepted.push(file);
      }
    }
    setErrors(rejected);
    if (accepted.length) addFiles(accepted);
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <div>
        <Button  variant="ghost" size="sm" className="mb-4 -ml-3" nativeButton={false} role="link" render={<Link to="/sales" />}> <ArrowLeft /> Sales &amp; GSTR-1</Button>
        <h1 className="text-2xl font-semibold tracking-tight">Add sales bills</h1>
        <p className="mt-2 text-sm text-muted-foreground">{monthLabel} · Select your sales bills as PDFs.</p>
      </div>

      <Card className="gap-0 overflow-hidden py-0 shadow-none">
        <div
          className={`m-6 flex flex-col items-center rounded-lg border border-dashed px-6 py-12 text-center transition-colors ${dragging ? "border-foreground bg-muted" : "border-border"}`}
          onDragOver={(event) => { event.preventDefault(); setDragging(true); }}
          onDragLeave={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragging(false);
          }}
          onDrop={(event) => {
            event.preventDefault();
            setDragging(false);
            selectFiles(Array.from(event.dataTransfer.files));
          }}
        >
          <div className="mb-4 flex size-11 items-center justify-center rounded-lg border bg-background">
            <Upload className="size-5 text-muted-foreground" aria-hidden="true" />
          </div>
          <h2 className="text-sm font-medium">Drop your sales PDFs here</h2>
          <p className="mt-2 text-sm text-muted-foreground">One bill or a combined PDF of several bills.</p>
          <Button className="mt-5" onClick={() => picker.current?.click()}>Choose PDFs</Button>
          <Input
            ref={picker}
            id="sales-pdf-picker"
            className="hidden"
            type="file"
            accept=".pdf,application/pdf"
            multiple
            aria-label="Choose sales PDF files"
            onChange={(event) => {
              selectFiles(Array.from(event.currentTarget.files ?? []));
              event.currentTarget.value = "";
            }}
          />
        </div>
        <p className="border-t bg-muted/40 px-6 py-4 text-sm text-muted-foreground">
          Files stay in this browser session. This preview does not upload files or read invoices.
        </p>
      </Card>

      {errors.length > 0 && (
        <div role="alert" className="rounded-lg border border-destructive/30 px-4 py-3 text-sm text-destructive">
          <p className="font-medium">Some files could not be selected</p>
          <ul className="mt-2 list-inside list-disc space-y-1 break-words">
            {errors.map((error, index) => <li key={index}>{error}</li>)}
          </ul>
        </div>
      )}

      {files.length > 0 && (
        <section aria-labelledby="selected-files-heading" className="space-y-3">
          <div className="flex items-center justify-between gap-4">
            <h2 id="selected-files-heading" className="text-sm font-semibold" aria-live="polite">
              {files.length} {files.length === 1 ? "file" : "files"} selected
            </h2>
            <Button variant="ghost" size="sm" onClick={() => { clearFiles(); setErrors([]); }}>Clear all</Button>
          </div>
          <ul className="divide-y rounded-lg border bg-card">
            {files.map((file, index) => (
              <li key={`${file.name}-${file.size}-${file.lastModified}`} className="flex items-center gap-3 px-4 py-3">
                <FileText className="size-5 shrink-0 text-muted-foreground" aria-hidden="true" />
                <div className="min-w-0 flex-1">
                  <p className="break-words text-sm font-medium">{file.name}</p>
                  <p className="mt-1 text-xs text-muted-foreground">PDF · {fileSize(file.size)}</p>
                </div>
                <Button variant="ghost" size="icon" aria-label={`Remove ${file.name}`} onClick={() => removeFile(index)}><X /></Button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="flex justify-end">
        <Button  variant="outline" nativeButton={false} role="link" render={<Link to="/sales/uploads" />}> View uploads <ArrowRight /></Button>
      </div>
    </div>
  );
}
