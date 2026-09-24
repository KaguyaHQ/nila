import { Skeleton } from "@/components/ui/skeleton";

export function ListSkeleton({ label }: { label: string }) {
  return (
    <div role="status" aria-label={label} aria-busy="true" className="space-y-8">
      <span className="sr-only">{label}</span>
      <div aria-hidden="true" className="space-y-8">
        <div className="flex items-center justify-between">
          <Skeleton className="h-8 w-52" />
          <Skeleton className="h-9 w-32" />
        </div>
        <Skeleton className="h-9 w-80" />
        <div className="rounded-xl border bg-card px-5">
          {Array.from({ length: 6 }, (_, i) => (
            <div
              key={i}
              className="flex items-center justify-between gap-8 border-b py-5 last:border-0"
            >
              <Skeleton className="h-4 w-64" />
              <Skeleton className="h-4 w-40" />
              <Skeleton className="h-4 w-20" />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
