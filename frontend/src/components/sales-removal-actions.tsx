import { useEffect, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { MoreHorizontal } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogAction,
  AlertDialogCancel,
} from "@/components/ui/alert-dialog";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { toast } from "@/components/ui/toast";
import { changeUploadRemoval } from "@/lib/upload-api";
import { urlDestination } from "@/lib/route-url";

type Selection = { action: "remove" | "restore"; source_ids: string[] };
export function SalesRemovalActions({
  clientId,
  clientName,
  period,
  batchRef,
  activeIds,
  removedIds = [],
  invoiceNumber,
  afterRemoveUrl,
  restoreOnly = false,
  disabled = false,
}: {
  clientId: number;
  clientName: string;
  period: string;
  batchRef: string;
  activeIds: string[];
  removedIds?: string[];
  invoiceNumber?: string;
  afterRemoveUrl?: string;
  restoreOnly?: boolean;
  disabled?: boolean;
}) {
  const [selection, setSelection] = useState<Selection | null>(null);
  const request = useRef<AbortController | null>(null);
  const cancel = useRef<HTMLButtonElement | null>(null);
  const trigger = useRef<HTMLButtonElement | null>(null);
  const guard = useRef(false);
  const cache = useQueryClient();
  const navigate = useNavigate();
  useEffect(() => () => request.current?.abort(), []);
  const affected = (query: { queryKey: readonly unknown[] }) =>
    ["sales", "sales-review", "sales-invoice", "sales-uploads", "upload-move"].includes(
      String(query.queryKey[0]),
    );
  const mutation = useMutation({
    mutationFn: (body: Selection) => {
      request.current = new AbortController();
      return changeUploadRemoval(clientId, period, batchRef, body, request.current.signal);
    },
    retry: false,
    networkMode: "always",
    onSuccess: async (_, body) => {
      await cache.invalidateQueries({ predicate: affected, refetchType: "none" });
      setSelection(null);
      if (body.action === "remove" && afterRemoveUrl)
        await navigate(urlDestination(afterRemoveUrl));
      await cache.refetchQueries({ predicate: affected, type: "active" });
      toast.add({
        title: body.action === "remove" ? "Removed from the working" : "Restored to the working",
        type: "success",
      });
    },
    onSettled: () => {
      guard.current = false;
    },
  });
  function choose(action: Selection["action"], ids: string[]) {
    mutation.reset();
    setSelection({ action, source_ids: ids });
  }
  const restoring = selection?.action === "restore";
  const month = new Date(`${period}-01T12:00:00`).toLocaleDateString("en-IN", {
    month: "long",
    year: "numeric",
  });
  const subject = invoiceNumber
    ? `invoice ${invoiceNumber}`
    : `${selection?.source_ids.length ?? 0} ${selection?.source_ids.length === 1 ? "invoice" : "invoices"}`;
  return (
    <>
      {restoreOnly ? (
        <Button
          variant="ghost"
          size="sm"
          ref={trigger}
          disabled={disabled || mutation.isPending}
          onClick={() => choose("restore", removedIds)}
        >
          Restore invoice {invoiceNumber}
        </Button>
      ) : (
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button
                variant="ghost"
                size="icon-sm"
                ref={trigger}
                aria-label={invoiceNumber ? "Invoice actions" : "Upload actions"}
                disabled={disabled || mutation.isPending}
              />
            }
          >
            <MoreHorizontal />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-64">
            <DropdownMenuItem
              variant="destructive"
              disabled={!activeIds.length}
              onClick={() => choose("remove", activeIds)}
            >
              Remove {invoiceNumber ? "invoice" : "upload"}…
            </DropdownMenuItem>
            {removedIds.length > 0 && (
              <DropdownMenuItem onClick={() => choose("restore", removedIds)}>
                Restore removed invoices…
              </DropdownMenuItem>
            )}
          </DropdownMenuContent>
        </DropdownMenu>
      )}
      <AlertDialog
        open={selection !== null}
        onOpenChange={(open) => {
          if (!open && !guard.current) setSelection(null);
        }}
      >
        <AlertDialogContent initialFocus={cancel} finalFocus={trigger}>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {restoring ? "Restore" : "Remove"} {subject}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              {restoring
                ? `Return to ${clientName}’s ${month} working with the saved corrections.`
                : `Remove from ${clientName}’s ${month} working. Files and corrections stay saved. Restore anytime from Uploads.`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          {mutation.isError && (
            <Alert variant="destructive">
              <AlertDescription>{mutation.error.message}</AlertDescription>
            </Alert>
          )}
          <AlertDialogFooter>
            <AlertDialogCancel ref={cancel} disabled={mutation.isPending}>
              Cancel
            </AlertDialogCancel>
            <AlertDialogAction
              variant={restoring ? "default" : "destructive"}
              disabled={mutation.isPending}
              onClick={() => {
                if (!selection || guard.current) return;
                guard.current = true;
                mutation.mutate(selection);
              }}
            >
              {mutation.isPending ? "Saving…" : restoring ? "Restore" : "Remove"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
