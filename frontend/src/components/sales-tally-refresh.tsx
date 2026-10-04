import { useEffect, useRef } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Info, RefreshCw } from "lucide-react";
import { Popover, PopoverContent, PopoverTitle, PopoverTrigger } from "@/components/ui/popover";
import {
  refreshSalesTally,
  tallyQueryKey,
  type EnabledTallySalesData,
} from "@/lib/sales-tally-api";

function dateLabel(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    timeZone: "Asia/Kolkata",
  }).format(date);
}
function completedLabel(value: string | null) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZone: "Asia/Kolkata",
  }).format(date);
}

export function TallyRefresh({
  clientId,
  period,
  data,
}: {
  clientId: string;
  period: string;
  data: EnabledTallySalesData;
}) {
  const cache = useQueryClient();
  const operation = useRef<AbortController | null>(null);
  const previous = useRef(data.sync.status);
  useEffect(() => () => operation.current?.abort(), []);
  useEffect(() => {
    const completed = previous.current === "running" && data.sync.status === "succeeded";
    previous.current = data.sync.status;
    if (completed) {
      void cache.invalidateQueries({ queryKey: tallyQueryKey(clientId, period) });
      void cache.invalidateQueries({ queryKey: ["sales", clientId, period] });
      void cache.invalidateQueries({ queryKey: ["sales-review", clientId, period] });
    }
  }, [cache, clientId, period, data.sync.status]);
  const refresh = useMutation({
    mutationKey: ["tally-sync", clientId, period],
    retry: false,
    networkMode: "always",
    mutationFn: (controller: AbortController) =>
      refreshSalesTally(clientId, period, controller.signal),
    onSuccess: async (result, controller) => {
      await cache.cancelQueries({ queryKey: tallyQueryKey(clientId, period), exact: true });
      if (!controller.signal.aborted) {
        cache.setQueryData(tallyQueryKey(clientId, period), result);
        if (result.enabled && result.sync.status === "succeeded") {
          void cache.invalidateQueries({ queryKey: ["sales", clientId, period] });
          void cache.invalidateQueries({ queryKey: ["sales-review", clientId, period] });
        }
      }
    },
    onError: () => {
      void cache.invalidateQueries({ queryKey: tallyQueryKey(clientId, period) });
    },
    onSettled: () => {
      operation.current = null;
    },
  });
  const running = refresh.isPending || data.sync.status === "running";
  return (
    <section
      aria-label="Refresh from Tally"
      className="flex flex-wrap items-center gap-1"
    >
      <Button
        variant="ghost"
        size="sm"
        aria-label={running ? "Refreshing from Tally…" : "Refresh from Tally"}
        disabled={!data.can_refresh || running}
        onClick={() => {
          if (running) return;
          const controller = new AbortController();
          operation.current = controller;
          refresh.mutate(controller);
        }}
      >
        <RefreshCw className={running ? "animate-spin" : undefined} />
        {running ? "Refreshing…" : "Refresh"}
      </Button>
      {(data.sync.covered || data.sync.last_completed_at) && (
        <Popover>
          <PopoverTrigger render={<Button variant="ghost" size="icon-sm" aria-label="Tally sync details" />}>
            <Info />
          </PopoverTrigger>
          <PopoverContent align="start">
            <PopoverTitle>Tally sync details</PopoverTitle>
            {data.sync.last_completed_at && <p className="text-muted-foreground">Updated {completedLabel(data.sync.last_completed_at)}</p>}
            {data.sync.covered && <p className="text-muted-foreground">Books {dateLabel(data.sync.period_start)}–{dateLabel(data.sync.period_end)}</p>}
          </PopoverContent>
        </Popover>
      )}
      {running && (
        <p role="status" className="text-sm text-muted-foreground">
          Reading Tally entries for {period}. Posting waits until this refresh finishes.
        </p>
      )}
      {!data.sync.covered && !running && data.sync.status === "not_synced" && (
        <p className="text-sm text-muted-foreground">
          Tally entries for this month have not been refreshed yet.
        </p>
      )}
      {data.sync.status === "offline" && (
        <p role="status" className="text-sm text-muted-foreground">
          Nila Connector is offline. Open it on the Tally computer to refresh this month.
        </p>
      )}
      {data.sync.status === "failed" && (
        <p role="alert" className="text-sm">
          {data.sync.error || "The Tally refresh failed. Try again."}
        </p>
      )}
      {refresh.isError && (
        <p role="alert" className="text-sm">
          {refresh.error.message}
        </p>
      )}
    </section>
  );
}
