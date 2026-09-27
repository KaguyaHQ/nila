import { useMutation } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { BusinessApiError, createBusinessWorkspace } from "@/lib/business-api";

export function AddBusinessDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [name, setName] = useState("");
  const [gstin, setGstin] = useState("");
  const create = useMutation({
    mutationFn: createBusinessWorkspace,
    retry: false,
    networkMode: "always",
    onSuccess: ({ business }) => {
      window.location.assign(`/app/business/${business.id}/settings/business`);
    },
  });

  function close(next: boolean) {
    if (!next && create.isPending) return;
    onOpenChange(next);
    if (!next) {
      setName("");
      setGstin("");
      create.reset();
    }
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!create.isPending) create.mutate({ business: { name: name.trim(), gstin: gstin.trim() } });
  }

  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogContent>
        <DialogTitle>Add a business</DialogTitle>
        <DialogDescription>Create another business under your account.</DialogDescription>
        <form onSubmit={submit} className="space-y-4">
          <div className="space-y-2">
            <label htmlFor="new-business-name" className="text-sm font-medium">
              Business name
            </label>
            <Input
              id="new-business-name"
              required
              maxLength={255}
              autoFocus
              value={name}
              onChange={(event) => setName(event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <label htmlFor="new-business-gstin" className="text-sm font-medium">
              GSTIN
            </label>
            <Input
              id="new-business-gstin"
              required
              maxLength={15}
              value={gstin}
              onChange={(event) => setGstin(event.target.value.toUpperCase())}
            />
          </div>
          {create.isError && (
            <p role="alert" className="text-sm text-destructive">
              {create.error instanceof BusinessApiError && create.error.fields.gstin
                ? `GSTIN: ${create.error.fields.gstin}`
                : create.error.message}
            </p>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <Button
              type="button"
              variant="outline"
              disabled={create.isPending}
              onClick={() => close(false)}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={create.isPending}>
              {create.isPending ? "Adding…" : "Add business"}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
