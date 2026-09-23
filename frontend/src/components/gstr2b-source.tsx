import { useEffect, useRef, useState } from "react";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { Download, MoreHorizontal, RefreshCw } from "lucide-react";

import { Button } from "@/components/ui/button";

import { Input } from "@/components/ui/input";

import { Label } from "@/components/ui/label";

import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";

import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";

import { Gstr2bError, gstr2bRequest, type Gstr2bState, type Gstr2bChallenge } from "@/lib/gstr2b-api";



const preparing = (state?: Gstr2bState) => ["received", "extracting"].includes(state?.import.status ?? "");



// The parent keys this component by client/month, so a connection challenge cannot travel between workspaces.

export function Gstr2bSource({ client, period }: { client: number; period: string }) {

  const cache = useQueryClient();

  const key = ["gstr2b", client, period];

  const request = useRef<AbortController | null>(null);

  const awaitingFetch = useRef<{ fetchedAt: string | null } | null>(null);

  const opener = useRef<HTMLButtonElement>(null);

  const [downloading, setDownloading] = useState(false);

  const [downloadError, setDownloadError] = useState<string | null>(null);

  const [open, setOpen] = useState(false);

  const [username, setUsername] = useState("");

  const [otp, setOtp] = useState("");

  const [challenge, setChallenge] = useState<Gstr2bChallenge | null>(null);

  const query = useQuery({ queryKey: key, queryFn: ({ signal }) => gstr2bRequest(client, period, signal), retry: false,

    refetchInterval: query => query.state.data?.fetching || preparing(query.state.data) ? 2000 : false });

  const state = query.data;

  const connect = () => { setUsername(state?.connection.username ?? ""); setChallenge(null); setOtp(""); setDownloadError(null); mutation.reset(); setOpen(true); };

  type SourceWrite = { action: "fetch" | "otp" | "verify" | "import"; body: unknown; controller: AbortController };
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async ({ action, body, controller }: SourceWrite) => {
      if (action !== "otp") await cache.cancelQueries({ queryKey: key, exact: true });
      controller.signal.throwIfAborted();
      return gstr2bRequest<Gstr2bState | Gstr2bChallenge>(client, period, controller.signal, action, body);
    },
    onSuccess: async (result, { action, controller }) => {
      if (controller.signal.aborted) return;
      if (action === "otp") { setChallenge(result as Gstr2bChallenge); setOtp(""); }
      else {
        // Discard any status read started before this action finished.
        await cache.cancelQueries({ queryKey: key, exact: true });
        if (controller.signal.aborted) return;
        cache.setQueryData(key, result);
        if (action === "verify") { setOpen(false); setChallenge(null); setOtp(""); }
        void cache.invalidateQueries({ queryKey: key, exact: true });
      }
    },
    onError: (problem, { action, controller }) => {
      if (controller.signal.aborted) return;
      if (action === "fetch" || action === "verify") awaitingFetch.current = null;
      if (problem instanceof Gstr2bError && problem.code === "invalid_challenge") { setChallenge(null); setOtp(""); }
      if (problem instanceof Gstr2bError && problem.code === "connection_required") connect();
    },
    onSettled: (_result, _problem, { controller }) => {
      if (request.current === controller) request.current = null;
    },
  });
  const pending = mutation.isPending || downloading;
  const error = downloadError || (mutation.error instanceof Gstr2bError && mutation.error.code === "connection_required" ? null : mutation.error?.message);
  const busy = pending || !!state?.fetching || preparing(state);

  useEffect(() => () => request.current?.abort(), []);

  useEffect(() => {

    if (query.dataUpdatedAt) void cache.invalidateQueries({ queryKey: ["purchases", String(client), period] });

  }, [query.dataUpdatedAt, cache, client, period]);

  useEffect(() => {

    const expected = awaitingFetch.current;

    if (!expected || !state || state.fetching || pending) return;

    if (state.statement?.last_error || state.statement?.status === "failed") { awaitingFetch.current = null; return; }

    if (state.statement?.status === "ready" && state.statement.fetched_at && state.statement.fetched_at !== expected.fetchedAt) {

      awaitingFetch.current = null;

      if (state.import.needed && !preparing(state)) void act("import");

    }

  }, [state, pending]);

  function act(action: SourceWrite["action"], body: unknown = {}) {
    if (pending || request.current) return;
    const controller = new AbortController(); request.current = controller;
    setDownloadError(null);
    if (action === "fetch" || action === "verify") awaitingFetch.current = { fetchedAt: state?.statement?.fetched_at ?? null };
    mutation.mutate({ action, body, controller });
  }

  async function download() {

    const url = state?.statement?.download_url;

    if (!url) return;

    request.current?.abort(); const controller = new AbortController(); request.current = controller;

    setDownloadError(null); mutation.reset(); setDownloading(true);

    try {

      const response = await fetch(url, { signal: controller.signal, credentials: "same-origin" });

      if (!response.ok || !response.headers.get("content-type")?.includes("json")) throw new Error("Source JSON could not be downloaded. Please try again.");

      const blob = await response.blob(); if (controller.signal.aborted) return;

      const address = URL.createObjectURL(blob); const link = document.createElement("a");

      link.href = address; link.download = `GSTR-2B-${period}.json`; link.click(); URL.revokeObjectURL(address);

    } catch (problem) { if (!controller.signal.aborted) setDownloadError(problem instanceof Error ? problem.message : "Download failed."); }

    finally { if (request.current === controller) request.current = null; if (!controller.signal.aborted) setDownloading(false); }

  }

  const storedError = state?.import.error || state?.statement?.last_error;

  const fetchedAt = state?.statement?.fetched_at;

  const needsConnection = state?.connection.state !== "connected";

  return <div className="space-y-3">

    {fetchedAt && <p className="text-xs text-muted-foreground">Fetched {new Intl.DateTimeFormat("en-IN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Kolkata" }).format(new Date(fetchedAt))} IST</p>}

    {state?.availability_hint && <p className="text-sm text-muted-foreground">{state.availability_hint}</p>}

    <div className="flex items-center gap-2">

      <Button ref={opener} variant="outline" size="sm" disabled={!state || busy || !(needsConnection ? state.permissions.connect : state.permissions.fetch) || state.connection.state === "missing_gstin"} onClick={() => needsConnection ? connect() : void act("fetch")}>

        {state?.fetching ? <><RefreshCw className="animate-spin" />Fetching GSTR-2B…</> : preparing(state) ? "Preparing purchases…" : needsConnection ? state?.connection.state === "expired" ? "Reconnect GST" : "Connect GST" : state?.statement?.fetched_at ? <><RefreshCw />Refresh GSTR-2B</> : "Fetch GSTR-2B"}

      </Button>

      {state?.import.needed && !state.fetching && !preparing(state) && <Button size="sm" variant="outline" disabled={busy || !state.permissions.fetch} onClick={() => void act("import")}>{state.import.error ? "Retry preparation" : "Prepare for review"}</Button>}

      {state?.statement?.download_url && state.permissions.export && <DropdownMenu><DropdownMenuTrigger render={<Button variant="ghost" size="icon-sm" aria-label="GSTR-2B source actions" />}><MoreHorizontal /></DropdownMenuTrigger><DropdownMenuContent align="end" className="w-52"><DropdownMenuItem disabled={pending} onClick={() => void download()}><Download />Download source JSON</DropdownMenuItem></DropdownMenuContent></DropdownMenu>}

    </div>

    {state?.connection.state === "missing_gstin" && <p className="text-sm text-muted-foreground">Add this client’s GSTIN before connecting to GST.</p>}

    {state && state.connection.state !== "missing_gstin" && !state.permissions.fetch && !state.permissions.connect && <p className="text-sm text-muted-foreground">You do not have permission to fetch or connect GST for this month.</p>}

    {query.isPending && <p role="status" className="text-sm text-muted-foreground">Checking GST connection…</p>}

    {query.isError && <div role="alert" className="text-sm text-destructive">{query.error.message} <Button variant="link" size="sm" onClick={() => void query.refetch()}>Try again</Button></div>}

    {!open && (error || storedError) && <p role="alert" className="text-sm text-destructive">{error || storedError}</p>}

    <Dialog open={open} onOpenChange={value => { setOpen(value); if (!value) { request.current?.abort(); request.current = null; awaitingFetch.current = null; setDownloading(false); setChallenge(null); setOtp(""); setDownloadError(null); mutation.reset(); } }}>

      <DialogContent finalFocus={opener} className="sm:max-w-sm"><DialogHeader><DialogTitle>{challenge ? "Enter GST verification code" : "Connect GST"}</DialogTitle><DialogDescription>{challenge ? "Enter the six-digit OTP sent to the mobile number and email registered with GST." : "Use this client’s GST portal username. We’ll send an OTP to verify the connection."}</DialogDescription></DialogHeader>

        <form className="space-y-4" onSubmit={event => { event.preventDefault(); void (challenge ? act("verify", { challenge: challenge.challenge, otp }) : act("otp", { username: username.trim() })); }}>

          {challenge ? <div className="space-y-2"><Label htmlFor="gst-otp">Verification code</Label><Input id="gst-otp" autoFocus required disabled={pending} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} value={otp} onChange={event => setOtp(event.target.value.replace(/\D/g, ""))} /></div> : <div className="space-y-2"><Label htmlFor="gst-username">GST username</Label><Input id="gst-username" autoFocus required maxLength={100} disabled={pending} autoComplete="username" value={username} onChange={event => setUsername(event.target.value)} /></div>}

          {error && <p role="alert" className="text-sm text-destructive">{error}</p>}

          <Button type="submit" className="w-full" disabled={pending || (challenge ? otp.length !== 6 : !username.trim())}>{pending ? "Please wait…" : challenge ? "Verify and fetch GSTR-2B" : "Send OTP"}</Button>

          {challenge && <Button type="button" variant="ghost" className="w-full" disabled={pending} onClick={() => { setChallenge(null); setOtp(""); setDownloadError(null); mutation.reset(); }}>Use another username or resend OTP</Button>}

        </form>

      </DialogContent>

    </Dialog>

  </div>;

}
