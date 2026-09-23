import { useEffect, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import {
  decidePurchaseSource,
  PurchaseReviewError,
  type PurchaseReviewData,
} from "@/lib/purchase-review-api";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
type Pair = NonNullable<PurchaseReviewData["item"]>["comparisons"][number];
type Action = "correct" | "confirm_pair" | "reject_pair";
export function PurchaseSourceActions({
  data,
  pair,
  disabled,
  onEditing,
}: {
  data: PurchaseReviewData;
  pair: Pair;
  disabled: boolean;
  onEditing: (open: boolean) => void;
}) {
  const [action, setAction] = useState<Action | null>(null);
  const [amounts, setAmounts] = useState(pair.correction);
  const [reason, setReason] = useState("");
  const controller = useRef<AbortController | null>(null);
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const cache = useQueryClient();
  useEffect(
    () => () => {
      controller.current?.abort();
    },
    [],
  );
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async () => {
      if (!action || !data.item?.source_basis || !pair.books_id || controller.current)
        throw new Error("Reopen the invoice before saving.");
      const request = new AbortController();
      controller.current = request;
      try {
        return await decidePurchaseSource(
          String(data.client.id),
          data.period,
          data.item.id,
          data.filter,
          data.q,
          {
            action,
            source_basis: data.item.source_basis,
            books_id: pair.books_id,
            ...(action === "correct"
              ? { amounts: amounts!, reason }
              : { portal_ref: pair.portal_ref! }),
          },
          request.signal,
        );
      } finally {
        if (controller.current === request) controller.current = null;
      }
    },
    onSuccess: async (fresh) => {
      await cache.cancelQueries({
        queryKey: ["purchase-review", String(data.client.id), data.period],
      });
      setAction(null);
      onEditing(false);
      await cache.invalidateQueries({
        queryKey: ["purchase-review", String(data.client.id), data.period],
        refetchType: "none",
      });
      await cache.invalidateQueries({ queryKey: ["purchases"], refetchType: "none" });
      if (fresh.item) {
        cache.setQueryData(
          [
            "purchase-review",
            String(data.client.id),
            data.period,
            fresh.item.id,
            data.filter,
            data.q,
          ],
          fresh,
        );
        navigate(
          `/gst/${data.client.id}/${data.period}/purchases/review/${encodeURIComponent(fresh.item.id)}?${params}`,
        );
      } else navigate(`/gst/${data.client.id}/${data.period}/purchases`);
    },
  });
  const needsRefresh =
    mutation.error instanceof PurchaseReviewError &&
    [403, 404, 409].includes(mutation.error.status);
  function open(value: Action) {
    setAction(value);
    onEditing(true);
    setAmounts(pair.correction);
    setReason("");
    mutation.reset();
  }
  function close() {
    if (mutation.isPending) return;
    setAction(null);
    onEditing(false);
    if (mutation.error)
      void cache.invalidateQueries({
        queryKey: ["purchase-review", String(data.client.id), data.period],
      });
  }
  if (!pair.books_id) return null;
  return (
    <div className="mt-3 flex gap-2">
      {pair.correction && (
        <Button variant="outline" size="sm" disabled={disabled} onClick={() => open("correct")}>
          Correct purchase values
        </Button>
      )}
      {pair.can_pair && (
        <>
          <Button size="sm" disabled={disabled} onClick={() => open("confirm_pair")}>
            Same invoice
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={disabled}
            onClick={() => open("reject_pair")}
          >
            Different invoices
          </Button>
        </>
      )}
      <Dialog
        open={action !== null}
        onOpenChange={(open) => {
          if (!open) close();
        }}
      >
        <DialogContent className="sm:max-w-xl">
          <DialogHeader>
            <DialogTitle>
              {action === "correct"
                ? "Correct purchase values"
                : action === "confirm_pair"
                  ? "Confirm this match?"
                  : "Reject this match?"}
            </DialogTitle>
            <DialogDescription>
              {action === "correct"
                ? "Use the original bill. Your reason and the original amounts are retained."
                : action === "confirm_pair"
                  ? "These purchase and GSTR-2B records represent the same invoice. This does not claim ITC."
                  : "These records represent different invoices. Nila will separate them and recalculate the comparison."}
            </DialogDescription>
          </DialogHeader>
          <form
            className="space-y-4"
            onSubmit={(e) => {
              e.preventDefault();
              if (!controller.current && !mutation.isPending) mutation.mutate();
            }}
          >
            {mutation.error && (
              <p role="alert" className="text-sm text-destructive">
                {mutation.error.message}
              </p>
            )}
            {action === "correct" && amounts && (
              <>
                <div className="grid grid-cols-2 gap-4">
                  {(Object.keys(amounts) as (keyof typeof amounts)[])
                    .filter((key) => key !== "cess" || amounts.cess !== "0.00")
                    .map((key) => (
                      <label key={key} className="space-y-2 text-sm block">
                        {
                          {
                            taxable_paise: "Taxable value",
                            total_paise: "Invoice total",
                            cgst: "CGST",
                            sgst: "SGST",
                            igst: "IGST",
                            cess: "CESS",
                          }[key]
                        }
                        <Input
                          required
                          inputMode="decimal"
                          disabled={mutation.isPending}
                          value={amounts[key]}
                          onChange={(e) => setAmounts({ ...amounts, [key]: e.target.value })}
                        />
                      </label>
                    ))}
                </div>
                <label className="block space-y-2 text-sm">
                  Reason for correction
                  <Textarea
                    required
                    maxLength={1000}
                    value={reason}
                    disabled={mutation.isPending}
                    onChange={(e) => setReason(e.target.value)}
                  />
                </label>
              </>
            )}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="ghost" disabled={mutation.isPending} onClick={close}>
                Cancel
              </Button>
              <Button type="submit" disabled={mutation.isPending || needsRefresh}>
                {mutation.isPending
                  ? "Saving…"
                  : action === "correct"
                    ? "Save correction"
                    : "Confirm decision"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
