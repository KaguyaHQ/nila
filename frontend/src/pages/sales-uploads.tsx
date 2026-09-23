import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { monthLabel } from "@/data/sales";
import { useUploadPreview } from "@/state/upload-preview";
import { Link } from "@tanstack/react-router";
import { ArrowLeft, ArrowRight, FileText, Plus } from "lucide-react";

export default function SalesUploads() {
  const { files } = useUploadPreview();

  return (
    <div className="space-y-6">
      <div>
        <Button
          variant="ghost"
          size="sm"
          className="mb-4 -ml-3"
          nativeButton={false}
          role="link"
          render={<Link to="/sales" />}
        >
          {" "}
          <ArrowLeft /> Sales &amp; GSTR-1
        </Button>
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">Uploads</h1>
            <p className="mt-2 text-sm text-muted-foreground">
              {monthLabel} · Sales bills behind your working.
            </p>
          </div>
          <Button nativeButton={false} role="link" render={<Link to="/sales/upload" />}>
            {" "}
            <Plus /> Add sales bills
          </Button>
        </div>
      </div>

      <Card className="gap-0 overflow-hidden py-0 shadow-none">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b px-6 py-4">
          <h2 className="text-sm font-semibold">Sales bills</h2>
          <p className="text-sm text-muted-foreground">1 batch · 1 file</p>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-5 px-6 py-5">
          <div className="flex min-w-0 items-center gap-4">
            <div className="flex size-10 shrink-0 items-center justify-center rounded-lg border">
              <FileText className="size-5 text-muted-foreground" aria-hidden="true" />
            </div>
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <p className="break-words text-sm font-medium">June sales bills.pdf</p>
                <Badge variant="secondary">Sample</Badge>
              </div>
              <p className="mt-1.5 text-sm text-muted-foreground">8 invoices in the working</p>
            </div>
          </div>
          <Button
            variant="outline"
            nativeButton={false}
            role="link"
            render={<Link to="/sales/register" />}
          >
            {" "}
            View register <ArrowRight />
          </Button>
        </div>
      </Card>

      {files.length > 0 && (
        <section aria-labelledby="local-files-heading" className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 id="local-files-heading" className="text-sm font-semibold">
                Selected in this browser
              </h2>
              <p className="mt-1 text-sm text-muted-foreground">
                {files.length} {files.length === 1 ? "file" : "files"} selected. These have not been
                uploaded or added to the working.
              </p>
            </div>
            <Button
              variant="outline"
              size="sm"
              nativeButton={false}
              role="link"
              render={<Link to="/sales/upload" />}
            >
              {" "}
              Manage files
            </Button>
          </div>
          <ul className="divide-y rounded-lg border bg-card">
            {files.map((file) => (
              <li
                key={`${file.name}-${file.size}-${file.lastModified}`}
                className="flex items-center gap-3 px-4 py-3"
              >
                <FileText className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                <span className="min-w-0 flex-1 break-words text-sm">{file.name}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
