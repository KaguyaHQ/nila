import { lazy, Suspense, useEffect, useState, type ReactNode } from "react";
import { ArrowUpRight, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

const SourcePdf = lazy(() => import("@/components/source-pdf"));
type Download = { url: string } | { error: string; expired: boolean } | null;

export function NoticePdf({
  url,
  reconnect,
  children,
}: {
  url: string;
  reconnect: () => void;
  children: ReactNode;
}) {
  const [revision, setRevision] = useState(0);
  const [download, setDownload] = useState<Download>(null);

  // biome-ignore lint/correctness/useExhaustiveDependencies: revision explicitly restarts a user-requested download.
  useEffect(() => {
    const controller = new AbortController();
    let objectUrl: string | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = async (attempt: number) => {
      try {
        const response = await fetch(url, { signal: controller.signal, cache: "no-store" });
        if (controller.signal.aborted) return;
        if (attempt === 0 && [502, 503, 504].includes(response.status)) {
          timer = setTimeout(() => void load(1), 800);
          return;
        }
        if (!response.ok) {
          setDownload({
            expired: response.status === 409,
            error:
              response.status === 409
                ? "GST login expired. Reconnect this client to download the document."
                : response.status === 401 || response.status === 403
                  ? "You don’t have access to this document. Sign in with an account that has access."
                  : response.status === 404
                    ? "This document is no longer available."
                    : "Couldn’t download this document from GST. Try again.",
          });
          return;
        }
        const blob = await response.blob();
        if (controller.signal.aborted) return;
        objectUrl = URL.createObjectURL(blob);
        setDownload({ url: objectUrl });
      } catch {
        if (controller.signal.aborted) return;
        if (attempt === 0) {
          timer = setTimeout(() => void load(1), 800);
        } else {
          setDownload({
            error: "Couldn’t download this document from GST. Try again.",
            expired: false,
          });
        }
      }
    };
    // Let an immediately cancelled mount finish before starting a GST request.
    void Promise.resolve().then(() => {
      if (!controller.signal.aborted) void load(0);
    });
    return () => {
      controller.abort();
      clearTimeout(timer);
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [url, revision]);

  const reload = () => {
    setDownload(null);
    setRevision((value) => value + 1);
  };

  return (
    <>
      <div className="flex items-center justify-between gap-4">
        {children}
        {download && "url" in download && (
          <div className="flex items-center gap-2">
            <Button variant="ghost" size="sm" onClick={reload}>
              <RefreshCw />
              Reload document
            </Button>
            <Button
              variant="outline"
              size="sm"
              nativeButton={false}
              role="link"
              render={<a href={download.url} target="_blank" rel="noopener noreferrer" />}
            >
              Open original
              <ArrowUpRight />
            </Button>
          </div>
        )}
      </div>
      <section
        aria-label="Original notice PDF"
        className="h-[calc(100vh-25rem)] min-h-[480px] overflow-hidden rounded-xl border"
      >
        {!download ? (
          <p role="status" className="p-6 text-sm text-muted-foreground">
            Loading document…
          </p>
        ) : "error" in download ? (
          <div role="alert" className="space-y-4 p-6">
            <p className="text-sm">{download.error}</p>
            <Button variant="outline" onClick={download.expired ? reconnect : reload}>
              {download.expired ? "Reconnect GST" : "Try again"}
            </Button>
          </div>
        ) : (
          <Suspense fallback={<Skeleton className="h-full" />}>
            <SourcePdf url={download.url} pages={[]} label="Notice" />
          </Suspense>
        )}
      </section>
    </>
  );
}
