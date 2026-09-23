import { useEffect, useRef } from "react";
import { ChevronLeft, ChevronRight, Download, Minus, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { PdfViewer } from "../../../assets/js/hooks/pdf_viewer.js";
import "../../../assets/vendor/pdfjs/text_layer.css";

// The existing renderer owns this subtree until unmount. Keying by source and
// selected pages keeps React from reconciling the canvases it manages.
export default function SourcePdf(props: {
  url: string;
  pages: number[];
  images?: string[];
  label?: string;
  zoom?: React.RefObject<number>;
}) {
  return <PdfSurface key={`${props.url}:${props.pages.join(",")}`} {...props} />;
}

function PdfSurface({
  url,
  pages,
  images = [],
  label = "Invoice",
  zoom,
}: {
  url: string;
  pages: number[];
  images?: string[];
  label?: string;
  zoom?: React.RefObject<number>;
}) {
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!root.current) return;
    const renderer = Object.assign({ el: root.current, zoom: 1 }, PdfViewer);
    renderer.mounted();
    if (zoom) renderer.zoom = zoom.current;
    return () => {
      if (zoom) zoom.current = renderer.zoom;
      renderer.destroyed();
    };
  }, [zoom]);

  return (
    <div
      ref={root}
      data-url={url}
      data-pages={JSON.stringify(pages)}
      data-has-fallback={images.length > 0 ? "true" : "false"}
      className="flex h-full min-h-0 flex-col"
    >
      <div className="flex flex-wrap items-center gap-1 border-b bg-background p-2">
        <Button
          variant="ghost"
          size="icon-sm"
          data-pdf-action="previous"
          aria-label="Previous PDF page"
        >
          <ChevronLeft />
        </Button>
        <span data-pdf-counter className="min-w-20 text-center text-xs text-muted-foreground" />
        <Button variant="ghost" size="icon-sm" data-pdf-action="next" aria-label="Next PDF page">
          <ChevronRight />
        </Button>
        <Button variant="ghost" size="icon-sm" data-pdf-action="out" aria-label="Zoom out">
          <Minus />
        </Button>
        <Button variant="ghost" size="icon-sm" data-pdf-action="in" aria-label="Zoom in">
          <Plus />
        </Button>
        <Button variant="ghost" size="sm" data-pdf-action="fit">
          Fit width
        </Button>
        <Button
          variant="ghost"
          size="icon-sm"
          className="ml-auto"
          nativeButton={false}
          role="link"
          render={<a href={url} target="_blank" rel="noopener noreferrer" />}
          aria-label="Download source PDF"
        >
          <Download />
        </Button>
      </div>
      <p data-pdf-status role="status" className="px-3 py-2 text-sm text-muted-foreground">
        Loading PDF…
      </p>
      <div data-pdf-fallback hidden className="min-h-0 overflow-auto">
        {images.map((image, index) => (
          <img key={image} src={image} alt={`Saved invoice page ${index + 1}`} className="w-full" />
        ))}
      </div>
      <div
        data-pdf-surface
        tabIndex={0}
        aria-label={`${label} PDF`}
        className="min-h-0 flex-1 space-y-4 overflow-auto bg-muted/30 p-3 outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
      >
        {(pages.length ? pages : [1]).map((page) => (
          <div key={page} data-pdf-page={page} className="relative mx-auto bg-white">
            <canvas
              aria-label={`Original ${label.toLowerCase()} PDF page ${page}`}
              className="block"
            />
            <div data-pdf-text className="nila-pdf-text-layer" />
          </div>
        ))}
      </div>
    </div>
  );
}
