import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Combobox,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
} from "@/components/ui/combobox";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { toast } from "@/components/ui/toast";
import { moveUpload, previewUploadMove, type UploadMovePreview } from "@/lib/upload-api";
import { urlDestination } from "@/lib/route-url";

type Client = UploadMovePreview["clients"][number];

export function MoveSalesUpload({
  clientId,
  clientName,
  period,
  batchRef,
  open: controlledOpen,
  onOpenChange,
  finalFocus,
}: {
  clientId: number;
  clientName: string;
  period: string;
  batchRef: string;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  finalFocus?: React.RefObject<HTMLButtonElement | null>;
}) {
  const [localOpen, setLocalOpen] = useState(false);
  const open = controlledOpen ?? localOpen;
  const setOpen = onOpenChange ?? setLocalOpen;
  const [selected, setSelected] = useState<Client | null>(null);
  const guard = useRef(false);
  const request = useRef<AbortController | null>(null);
  useEffect(() => () => request.current?.abort(), [clientId, period, batchRef]);
  const cache = useQueryClient();
  const navigate = useNavigate();
  const preview = useQuery({
    queryKey: ["upload-move", clientId, period, batchRef],
    queryFn: ({ signal }) => previewUploadMove(clientId, period, batchRef, signal),
    enabled: open,
    staleTime: 0,
    retry: false,
  });
  const mutation = useMutation({
    mutationFn: ({ destination, basis }: { destination: number; basis: string }) => {
      request.current = new AbortController();
      return moveUpload(clientId, period, batchRef, destination, basis, request.current.signal);
    },
    retry: false,
    networkMode: "always",
    onSuccess: async (result) => {
      // Both month workspaces, the upload history and any open invoice queues changed.
      await cache.invalidateQueries({
        refetchType: "none",
        predicate: (query) =>
          [
            "sales",
            "sales-review",
            "sales-invoice",
            "sales-uploads",
            "sales-upload-result",
            "upload-move",
            "clients",
          ].includes(String(query.queryKey[0])),
      });
      setOpen(false);
      await navigate(urlDestination(result.review_url));
      toast.add({ title: `Moved ${result.invoice_count} invoices`, type: "success" });
    },
    onSettled: () => {
      guard.current = false;
    },
  });
  const data = preview.data;
  const choices = data?.clients ?? [];
  const month = new Date(`${period}-01T12:00:00`).toLocaleDateString("en-IN", {
    month: "long",
    year: "numeric",
  });
  function changeOpen(value: boolean) {
    if (guard.current) return;
    setOpen(value);
    setSelected(null);
    mutation.reset();
  }
  return (
    <Dialog open={open} onOpenChange={changeOpen}>
      {controlledOpen === undefined && (
        <DialogTrigger render={<Button variant="outline" size="sm" />}>Move upload…</DialogTrigger>
      )}
      <DialogContent showCloseButton={!mutation.isPending} finalFocus={finalFocus}>
        <DialogHeader>
          <DialogTitle>Move upload to another client</DialogTitle>
          <DialogDescription>
            Keep the original PDFs and corrections. Review checks will run again for the new client.
          </DialogDescription>
        </DialogHeader>
        {preview.isPending ? (
          <p role="status">Loading upload…</p>
        ) : preview.isError ? (
          <>
            <Alert variant="destructive">
              <AlertDescription>{preview.error.message}</AlertDescription>
            </Alert>
            <Button variant="outline" onClick={() => preview.refetch()}>
              Try again
            </Button>
          </>
        ) : (
          data && (
            <>
              <div className="space-y-1 text-sm">
                <p className="font-medium">
                  {data.invoice_count} invoices · {data.files.length}{" "}
                  {data.files.length === 1 ? "PDF" : "PDFs"}
                </p>
                <p className="text-muted-foreground">Seller on the bills: {data.seller.name}</p>
                <p className="text-muted-foreground">GSTIN {data.seller.gstin}</p>
              </div>
              <div className="space-y-2">
                <p id="move-client-label" className="text-sm font-medium">
                  Destination client
                </p>
                <Combobox
                  items={choices}
                  value={selected}
                  onValueChange={setSelected}
                  itemToStringLabel={(item) => `${item.name} ${item.gstin ?? ""}`}
                  isItemEqualToValue={(a, b) => a.id === b.id}
                  disabled={mutation.isPending}
                >
                  <ComboboxInput
                    aria-labelledby="move-client-label"
                    placeholder="Search client name or GSTIN"
                  />
                  <ComboboxContent>
                    <ComboboxEmpty>No clients found.</ComboboxEmpty>
                    <ComboboxList>
                      {(item: Client) => (
                        <ComboboxItem key={item.id} value={item}>
                          <span>
                            <span className="block">{item.name}</span>
                            <span className="block text-xs text-muted-foreground">
                              {item.gstin ?? "GSTIN not provided"}
                            </span>
                          </span>
                        </ComboboxItem>
                      )}
                    </ComboboxList>
                  </ComboboxContent>
                </Combobox>
                <p className="text-xs text-muted-foreground">
                  Client missing?{" "}
                  <Link
                    to="/clients/new"
                    search={{ period }}
                    target="_blank"
                    className="underline underline-offset-4"
                  >
                    Add client in a new tab
                  </Link>
                  , then{" "}
                  <Button
                    variant="link"
                    className="h-auto p-0 text-xs"
                    disabled={mutation.isPending || preview.isFetching}
                    onClick={() => preview.refetch()}
                  >
                    refresh this list
                  </Button>
                  .
                </p>
              </div>
              <p className="rounded-lg bg-muted p-3 text-sm">
                {selected
                  ? `Move ${data.invoice_count} invoices from ${clientName} to ${selected.name} · ${month}.`
                  : `The working month stays ${month}.`}
              </p>
              {selected && selected.gstin !== data.seller.gstin && (
                <p role="alert" className="text-sm text-destructive">
                  Choose a client whose GSTIN matches the seller on these bills.
                </p>
              )}
              {mutation.isError && (
                <Alert variant="destructive">
                  <AlertDescription>{mutation.error.message}</AlertDescription>
                </Alert>
              )}
              <DialogFooter>
                <Button
                  variant="outline"
                  disabled={mutation.isPending}
                  onClick={() => changeOpen(false)}
                >
                  Cancel
                </Button>
                <Button
                  disabled={
                    !selected ||
                    selected.gstin !== data.seller.gstin ||
                    mutation.isPending ||
                    preview.isFetching
                  }
                  onClick={() => {
                    if (!selected || guard.current) return;
                    guard.current = true;
                    mutation.mutate({ destination: selected.id, basis: data.basis });
                  }}
                >
                  {mutation.isPending ? "Moving…" : "Move upload"}
                </Button>
              </DialogFooter>
            </>
          )
        )}
      </DialogContent>
    </Dialog>
  );
}
