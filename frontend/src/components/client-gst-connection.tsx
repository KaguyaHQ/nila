import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent } from "@/components/ui/dialog";
import { GstOtpForm } from "@/components/gst-otp-form";
import {
  ClientApiError,
  fetchGstConnection,
  requestGstOtp,
  verifyGstConnection,
} from "@/lib/clients-api";

export function ClientGstConnection({ clientId }: { clientId: number }) {
  const cache = useQueryClient();
  const key = ["gst-connection", clientId];
  const query = useQuery({
    queryKey: key,
    queryFn: ({ signal }) => fetchGstConnection(clientId, signal),
    retry: false,
  });
  const [open, setOpen] = useState(false);
  const [username, setUsername] = useState("");
  const [otp, setOtp] = useState("");
  const [challenge, setChallenge] = useState<string | null>(null);
  const request = useRef<AbortController | null>(null);
  const opener = useRef<HTMLButtonElement>(null);
  useEffect(() => () => request.current?.abort(), []);
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async ({
      controller,
      challenge,
      username,
      otp,
    }: {
      controller: AbortController;
      challenge: string | null;
      username: string;
      otp: string;
    }) =>
      challenge
        ? verifyGstConnection(clientId, challenge, otp, controller.signal)
        : requestGstOtp(clientId, username, controller.signal),
    onSuccess: async (result, { controller }) => {
      if (controller.signal.aborted) return;
      if ("challenge" in result) {
        setChallenge(result.challenge);
        setOtp("");
        return;
      }
      await cache.cancelQueries({ queryKey: key });
      if (controller.signal.aborted) return;
      cache.setQueryData(key, result);
      setOpen(false);
      setChallenge(null);
      setOtp("");
      void cache.invalidateQueries({ queryKey: ["gstr2b"] });
      void cache.invalidateQueries({ queryKey: ["notices"] });
    },
    onError: (error, { controller }) => {
      if (
        !controller.signal.aborted &&
        error instanceof ClientApiError &&
        error.code === "invalid_challenge"
      ) {
        setChallenge(null);
        setOtp("");
      }
    },
    onSettled: (_result, _error, { controller }) => {
      if (request.current === controller) request.current = null;
    },
  });
  const close = (value: boolean) => {
    setOpen(value);
    if (!value) {
      request.current?.abort();
      request.current = null;
      setChallenge(null);
      setOtp("");
      mutation.reset();
    }
  };
  const state = query.data;
  return (
    <section aria-labelledby="client-gst-heading" className="rounded-lg border bg-card p-6">
      <div className="flex items-center justify-between gap-6">
        <div className="space-y-1">
          <h2 id="client-gst-heading" className="font-semibold">
            GST connection
          </h2>
          {state && (
            <p className="text-sm text-muted-foreground">
              {
                {
                  connected: "GST portal connected",
                  expired: "GST login expired",
                  not_connected: "Not connected",
                  missing_gstin: "Save a valid GSTIN above to connect.",
                }[state.state]
              }
            </p>
          )}
          {state?.username && <p className="text-sm text-muted-foreground">{state.username}</p>}
          {query.isPending && (
            <p role="status" className="text-sm text-muted-foreground">
              Checking connection…
            </p>
          )}
        </div>
        {state && state.can_connect && state.state !== "missing_gstin" && (
          <Button
            ref={opener}
            variant="outline"
            onClick={() => {
              setUsername(state.username ?? "");
              setChallenge(null);
              setOtp("");
              mutation.reset();
              setOpen(true);
            }}
          >
            {state.state === "not_connected" ? "Connect GST" : "Reconnect"}
          </Button>
        )}
      </div>
      {state && !state.can_connect && (
        <p className="mt-2 text-sm text-muted-foreground">
          Ask the firm owner to manage this connection.
        </p>
      )}
      {query.isError && (
        <div className="mt-2 space-y-2">
          <p role="alert" className="text-sm text-destructive">
            {query.error.message}
          </p>
          <Button variant="outline" onClick={() => query.refetch()}>
            Try again
          </Button>
        </div>
      )}
      <Dialog open={open} onOpenChange={close}>
        <DialogContent finalFocus={opener} className="sm:max-w-sm">
          <GstOtpForm
            challenge={Boolean(challenge)}
            username={username}
            setUsername={setUsername}
            otp={otp}
            setOtp={setOtp}
            pending={mutation.isPending}
            error={mutation.error?.message}
            verifyLabel="Verify connection"
            onSubmit={() => {
              if (request.current) return;
              const controller = new AbortController();
              request.current = controller;
              mutation.mutate({ controller, challenge, username: username.trim(), otp });
            }}
            onReset={() => {
              setChallenge(null);
              setOtp("");
              mutation.reset();
            }}
          />
        </DialogContent>
      </Dialog>
    </section>
  );
}
