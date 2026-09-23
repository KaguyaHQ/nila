import { RecordTableRow, RecordTableLink } from "@/components/record-table-row";
import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  ArrowLeft,
  ArrowUpRight,
  RefreshCw,
  Search,
  Inbox,
  CircleAlert,
  ChevronDown,
} from "lucide-react";
import { Shell } from "@/components/workspace-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { NativeSelect } from "@/components/ui/native-select";
import { Collapsible, CollapsibleTrigger, CollapsibleContent } from "@/components/ui/collapsible";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from "@/components/ui/sheet";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  noticesRequest,
  NoticesError,
  type NoticesData,
  type Notice,
  type NoticeClient,
} from "@/lib/notices-api";

const SourcePdf = lazy(() => import("@/components/source-pdf"));
const queryKey = ["notices"];
const labels: Record<NoticeClient["state"], string> = {
  missing_gstin: "GSTIN missing",
  not_connected: "Not connected",
  expired: "GST login expired",
  failed: "Check failed",
  not_checked: "Not checked yet",
  checking: "Checking…",
  checked: "Checked successfully",
};
const date = (value: string | null) =>
  value
    ? new Intl.DateTimeFormat("en-IN", {
        day: "numeric",
        month: "short",
        year: "numeric",
        timeZone: "Asia/Kolkata",
      }).format(new Date(value))
    : "Not supplied";
const checkedAt = (value: string | null) =>
  value
    ? `${new Intl.DateTimeFormat("en-IN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Kolkata" }).format(new Date(value))} IST`
    : "Never checked";

function useNoticeWrite<T, R>(
  save: (value: T, signal: AbortSignal) => Promise<R>,
  success: (result: R) => void,
) {
  const request = useRef<AbortController | null>(null);
  useEffect(() => () => request.current?.abort(), []);
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({ value, controller }: { value: T; controller: AbortController }) =>
      save(value, controller.signal),
    onSuccess: (result, { controller }) => {
      if (!controller.signal.aborted) success(result);
    },
    onSettled: (_result, _error, { controller }) => {
      if (request.current === controller) request.current = null;
    },
  });
  return {
    ...mutation,
    act: (value: T) => {
      if (request.current) return;
      const controller = new AbortController();
      request.current = controller;
      mutation.mutate({ value, controller });
    },
  };
}

export default function NoticesPage() {
  const { noticeId } = useParams();
  const [params, setParams] = useSearchParams();
  const cache = useQueryClient();
  const [search, setSearch] = useState("");
  const [checks, setChecks] = useState(false);
  const [unchecked, setUnchecked] = useState(false);
  const [connecting, setConnecting] = useState<NoticeClient | null>(null);
  const [checksClient, setChecksClient] = useState<number | null>(null);
  const [pdfRevision, setPdfRevision] = useState(0);
  const checksOpener = useRef<HTMLElement | null>(null);
  const connectionOpener = useRef<HTMLElement | null>(null);
  const query = useQuery({
    queryKey,
    queryFn: ({ signal }) => noticesRequest("getNotices", { signal }),
    retry: false,
    refetchInterval: (q) => (q.state.data?.checking ? 1500 : false),
  });
  const detail = useQuery({
    queryKey: ["notice", noticeId],
    queryFn: ({ signal }) => noticesRequest("getNotice", { id: Number(noticeId), signal }),
    enabled: !!noticeId,
    retry: false,
  });
  const data = query.data;
  const write = useNoticeWrite(
    async (action: { type: "all" | "retry" | "client"; id?: number }, signal) => {
      await cache.cancelQueries({ queryKey, exact: true });
      signal.throwIfAborted();
      if (action.type === "client")
        return noticesRequest("checkClientNotices", { id: action.id!, body: {}, signal });
      return action.type === "all"
        ? noticesRequest("checkAllNotices", { body: {}, signal })
        : noticesRequest("retryNotices", { body: {}, signal });
    },
    () => {
      void cache.invalidateQueries({ queryKey });
    },
  );
  const clientFilter = params.get("client_id") ?? "";
  useEffect(() => {
    if (write.error) void cache.invalidateQueries({ queryKey });
  }, [write.error, cache]);
  const visible = (data?.notices ?? []).filter(
    (n) =>
      (!clientFilter || String(n.client_id) === clientFilter) &&
      `${n.client_name} ${n.reference} ${n.type}`.toLowerCase().includes(search.toLowerCase()),
  );
  visible.sort((a, b) => (b.issued_on ?? "").localeCompare(a.issued_on ?? "") || b.id - a.id);
  const openChecks = (onlyFailed = false, client: number | null = null) => {
    checksOpener.current = document.activeElement as HTMLElement;
    write.reset();
    setUnchecked(onlyFailed);
    setChecksClient(client);
    setChecks(true);
  };
  const panelClients = (data?.clients ?? []).filter(
    (c) => (!checksClient || c.id === checksClient) && (!unchecked || c.run_error),
  );
  const error = write.error?.message;

  if (!data)
    return (
      <div className="mx-auto max-w-5xl p-12">
        <h1 className="text-2xl font-semibold">Notices</h1>
        {query.isPending ? (
          <Skeleton className="mt-8 h-64" />
        ) : (
          <div role="alert" className="mt-8 space-y-3">
            <p>{query.error?.message}</p>
            {query.error instanceof NoticesError && query.error.status === 401 ? (
              <a href="/users/log_in">Sign in</a>
            ) : (
              <Button onClick={() => void query.refetch()}>Try again</Button>
            )}
          </div>
        )}
      </div>
    );

  return (
    <Shell firm={data.user} clients={data.clients} notices>
      {noticeId ? (
        <NoticeReader
          pdfRevision={pdfRevision}
          notice={detail.data?.notice}
          pending={detail.isPending}
          error={detail.error?.message}
          retry={() => void detail.refetch()}
          params={params}
          setDocument={(index) => setParams({ document: String(index) }, { replace: true })}
          connect={(id) => openChecks(false, id)}
        />
      ) : (
        <div className="space-y-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Notices</h1>
            </div>
            <Button
              disabled={
                !data.permissions.check || data.checking || write.isPending || !data.clients.length
              }
              onClick={() => write.act({ type: "all" })}
            >
              <RefreshCw className={data.checking ? "animate-spin" : ""} />
              {write.isPending
                ? "Starting check…"
                : data.checking
                  ? data.run && data.run.pending > 0
                    ? `Checking ${data.run.checked} of ${data.run.total} clients…`
                    : "Checking notices…"
                  : "Check all clients"}
            </Button>
          </div>
          <div aria-live="polite" className="space-y-1 text-sm">
            <div className="flex items-center gap-3">
              {data.run ? (
                data.run.failed > 0 ? (
                  <p className="flex items-center gap-2 font-medium">
                    <CircleAlert className="size-4" />
                    {data.run.failed} {data.run.failed === 1 ? "client wasn’t" : "clients weren’t"}{" "}
                    checked.
                  </p>
                ) : (
                  <p>
                    {data.run.checked} of {data.run.total} clients checked
                  </p>
                )
              ) : (
                <p className="text-muted-foreground">
                  {data.clients.length
                    ? "Run a check to look for new notices."
                    : "Add clients to start checking for notices."}
                </p>
              )}
              {data.clients.length > 0 && (
                <Button
                  variant="link"
                  size="sm"
                  className="h-auto p-0"
                  onClick={() => openChecks()}
                >
                  View clients
                </Button>
              )}
            </div>
            {data.run && (
              <p className="text-xs text-muted-foreground">
                {data.checking && data.run.pending > 0 ? "Check started" : "Last check"}:{" "}
                {checkedAt(data.run.started_at)}
              </p>
            )}
          </div>
          {query.isError && (
            <p role="alert" className="text-sm text-destructive">
              Could not refresh notices. Showing the last loaded results.{" "}
              <Button variant="link" onClick={() => void query.refetch()}>
                Try again
              </Button>
            </p>
          )}
          {error && !checks && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
          <div className="flex items-center gap-3">
            <div className="relative w-80">
              <Search className="absolute left-3 top-2.5 size-4 text-muted-foreground" />
              <Input
                data-shortcut-search
                aria-label="Search notices"
                placeholder="Search client or notice reference"
                className="pl-9"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
            <NativeSelect
              aria-label="Filter by client"
              className="w-60"
              value={clientFilter}
              onChange={(e) => setParams(e.target.value ? { client_id: e.target.value } : {})}
            >
              <option value="">All clients</option>
              {data.clients.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </NativeSelect>
          </div>
          <NoticeList
            notices={visible}
            empty={
              search || clientFilter ? "No notices match this filter." : "No notices saved yet."
            }
          />
          <Collapsible>
            <CollapsibleTrigger
              render={
                <Button variant="ghost" size="sm" className="group px-0 text-muted-foreground" />
              }
            >
              About notice coverage <ChevronDown className="group-data-panel-open:rotate-180" />
            </CollapsibleTrigger>
            <CollapsibleContent className="pt-2 text-sm text-muted-foreground">
              Checks cover the last 60 days. Coverage varies by notice type. Reply and closure
              status are not supplied; check the GST portal for the latest case status.
            </CollapsibleContent>
          </Collapsible>
        </div>
      )}
      <Sheet open={checks} onOpenChange={setChecks}>
        <SheetContent className="data-[side=right]:sm:max-w-xl" finalFocus={checksOpener}>
          <SheetHeader className="border-b p-6">
            <SheetTitle>Client checks</SheetTitle>
            <SheetDescription>
              Connection problems and the last successful notice check for each client.
            </SheetDescription>
          </SheetHeader>
          <div className="flex-1 space-y-4 overflow-auto px-6 pb-6">
            <div className="flex items-center justify-between gap-3">
              <NativeSelect
                aria-label="Show client checks"
                className="w-52"
                value={unchecked ? "unchecked" : "all"}
                onChange={(e) => {
                  setUnchecked(e.target.value === "unchecked");
                  setChecksClient(null);
                }}
              >
                <option value="all">All clients</option>
                <option value="unchecked">Unchecked in latest run</option>
              </NativeSelect>
              {!!data.run?.retry_count && (
                <Button
                  variant="outline"
                  disabled={write.isPending || data.checking || !data.permissions.check}
                  onClick={() => write.act({ type: "retry" })}
                >
                  Retry {data.run.retry_count}
                </Button>
              )}
            </div>
            {error && (
              <p role="alert" className="text-sm text-destructive">
                {error}
              </p>
            )}
            {!panelClients.length && (
              <p className="py-6 text-muted-foreground">No clients in this view.</p>
            )}
            {panelClients.map((c) => (
              <div key={c.id} className="space-y-3 border-b py-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <h3 className="font-medium">{c.name}</h3>
                    <p className="mt-1 text-xs text-muted-foreground">{c.gstin ?? "No GSTIN"}</p>
                  </div>
                  <Badge variant="outline">{labels[c.state]}</Badge>
                </div>
                <p className="text-xs text-muted-foreground">
                  Last successful check: {checkedAt(c.last_checked_at)}
                </p>
                {c.state !== "checking" && (c.error || c.run_error) && (
                  <p className="text-sm text-muted-foreground">
                    {c.error || `Latest all-client check: ${c.run_error}`}
                  </p>
                )}
                {c.state === "missing_gstin" ? (
                  data.permissions.check ? (
                    <Button
                      variant="outline"
                      size="sm"
                      nativeButton={false}
                      role="link"
                      render={<Link to={`/clients/${c.id}/edit`} />}
                    >
                      Add GSTIN
                    </Button>
                  ) : (
                    <p className="text-xs text-muted-foreground">
                      Ask an operator or owner to add the GSTIN.
                    </p>
                  )
                ) : c.state === "not_connected" || c.state === "expired" ? (
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={!data.permissions.connect}
                    onClick={() => {
                      connectionOpener.current = document.activeElement as HTMLElement;
                      setConnecting(c);
                    }}
                  >
                    {c.state === "expired" ? "Reconnect GST" : "Connect GST"}
                  </Button>
                ) : (
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={!data.permissions.check || c.state === "checking" || write.isPending}
                    onClick={() => write.act({ type: "client", id: c.id })}
                  >
                    {c.state === "checking" ? "Checking…" : "Check notices"}
                  </Button>
                )}
                {!data.permissions.connect && ["not_connected", "expired"].includes(c.state) && (
                  <p className="text-xs text-muted-foreground">
                    Ask the firm owner to connect GST.
                  </p>
                )}
              </div>
            ))}
          </div>
        </SheetContent>
      </Sheet>
      {connecting && (
        <NoticeConnection
          key={connecting.id}
          client={connecting}
          finalFocus={connectionOpener}
          close={() => setConnecting(null)}
          connected={() => {
            const id = connecting.id;
            setConnecting(null);
            setPdfRevision((value) => value + 1);
            void cache.invalidateQueries({ queryKey });
            write.act({ type: "client", id });
          }}
        />
      )}
    </Shell>
  );
}

function NoticeList({ notices, empty }: { notices: NoticesData["notices"]; empty: string }) {
  return (
    <section aria-label="Notices">
      <div className="overflow-hidden rounded-xl border bg-background">
        {!notices.length ? (
          <div className="flex items-center gap-3 px-5 py-7 text-sm text-muted-foreground">
            <Inbox className="size-5" />
            {empty}
          </div>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Notice</TableHead>
                <TableHead>Client</TableHead>
                <TableHead>Issued</TableHead>
                <TableHead>Reply by</TableHead>
                <TableHead>
                  <span className="sr-only">Open</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {notices.map((n) => (
                <RecordTableRow key={n.id}>
                  <TableCell className="py-4">
                    <RecordTableLink
                      to={`/notices/${n.id}`}
                      className="font-medium hover:underline"
                    >
                      {n.type}
                      {n.new && (
                        <Badge variant="secondary" className="ml-2">
                          New
                        </Badge>
                      )}
                      <span className="mt-1 block text-xs font-normal text-muted-foreground">
                        {n.reference}
                      </span>
                    </RecordTableLink>
                  </TableCell>
                  <TableCell>{n.client_name}</TableCell>
                  <TableCell className="text-muted-foreground">{date(n.issued_on)}</TableCell>
                  <TableCell>{date(n.reply_due_on)}</TableCell>
                  <TableCell className="text-right">
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      nativeButton={false}
                      role="link"
                      render={<Link to={`/notices/${n.id}`} />}
                      aria-label={`Open notice ${n.reference}`}
                    >
                      <ArrowUpRight />
                    </Button>
                  </TableCell>
                </RecordTableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>
    </section>
  );
}

function NoticeReader({
  pdfRevision,
  notice,
  pending,
  error,
  retry,
  params,
  setDocument,
  connect,
}: {
  pdfRevision: number;
  notice?: Notice;
  pending: boolean;
  error?: string;
  retry: () => void;
  params: URLSearchParams;
  setDocument: (index: number) => void;
  connect: (id: number) => void;
}) {
  const [reload, setReload] = useState(0);
  const selected = Number(params.get("document"));
  const defaultIndex = Math.max(
    0,
    notice?.documents.findIndex((d) => d.type === "application/pdf") ?? 0,
  );
  const index =
    params.has("document") &&
    Number.isInteger(selected) &&
    selected >= 0 &&
    selected < (notice?.documents.length ?? 0)
      ? selected
      : defaultIndex;
  const document = notice?.documents[index];
  return (
    <div className="space-y-6">
      <Link
        to={notice ? `/notices?client_id=${notice.client_id}` : "/notices"}
        className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="size-4" />
        Back to notices
      </Link>
      {pending ? (
        <Skeleton className="h-96" />
      ) : error || !notice ? (
        <div role="alert" className="space-y-3">
          <p>{error ?? "Notice not found."}</p>
          <Button onClick={retry}>Try again</Button>
        </div>
      ) : (
        <>
          <div className="flex items-start justify-between gap-4">
            <div>
              <h1 className="text-2xl font-semibold">{notice.type}</h1>
              <p className="mt-2 text-muted-foreground">
                {notice.client_name} · {notice.reference}
              </p>
            </div>
            <Button variant="outline" onClick={() => connect(notice.client_id)}>
              Client GST connection
            </Button>
          </div>
          <dl className="flex flex-wrap gap-x-10 gap-y-4 border-y py-4 text-sm">
            {[
              ["GSTIN", notice.gstin],
              ["Issued", date(notice.issued_on)],
              ["Reply date in notice", date(notice.reply_due_on)],
              ["Tax period", notice.period],
            ]
              .filter(([, value]) => value)
              .map(([label, value]) => (
                <div key={label}>
                  <dt className="text-xs text-muted-foreground">{label}</dt>
                  <dd className="mt-1 font-medium">{value}</dd>
                </div>
              ))}
          </dl>
          <p className="text-xs text-muted-foreground">
            Reply and closure status are not supplied. Check the GST portal for the latest case
            status.
          </p>
          {document ? (
            <>
              <div className="flex items-center justify-between gap-4">
                <div className="flex items-center gap-3">
                  <Label htmlFor="notice-document">Document</Label>
                  <NativeSelect
                    id="notice-document"
                    className="w-80"
                    value={index}
                    onChange={(e) => setDocument(Number(e.target.value))}
                  >
                    {notice.documents.map((d, i) => (
                      <option key={i} value={i}>
                        {d.name}
                      </option>
                    ))}
                  </NativeSelect>
                </div>
                {document.type === "application/pdf" && (
                  <div className="flex items-center gap-2">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setReload((value) => value + 1)}
                    >
                      <RefreshCw />
                      Reload document
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      nativeButton={false}
                      role="link"
                      render={<a href={document.url} target="_blank" rel="noopener noreferrer" />}
                    >
                      Open original
                      <ArrowUpRight />
                    </Button>
                  </div>
                )}
              </div>
              {document.type === "application/pdf" ? (
                <section
                  aria-label="Original notice PDF"
                  className="h-[calc(100vh-25rem)] min-h-[480px] overflow-hidden rounded-xl border"
                >
                  <Suspense fallback={<Skeleton className="h-full" />}>
                    <SourcePdf
                      key={`${pdfRevision}:${reload}`}
                      url={document.url}
                      pages={[]}
                      label="Notice"
                    />
                  </Suspense>
                </section>
              ) : (
                <p className="py-10 text-sm text-muted-foreground">
                  Preview unavailable for this file type. View this attachment on the GST portal.
                </p>
              )}
            </>
          ) : (
            <p className="py-10 text-sm text-muted-foreground">
              No documents are available for this notice.
            </p>
          )}
        </>
      )}
    </div>
  );
}

function NoticeConnection({
  client,
  close,
  connected,
  finalFocus,
}: {
  client: NoticeClient;
  close: () => void;
  connected: () => void;
  finalFocus: React.RefObject<HTMLElement | null>;
}) {
  const [username, setUsername] = useState(client.username),
    [otp, setOtp] = useState(""),
    [challenge, setChallenge] = useState<string | null>(null);
  const write = useNoticeWrite(
    async (_: void, signal) =>
      challenge
        ? noticesRequest("verifyNoticeOtp", { id: client.id, body: { challenge, otp }, signal })
        : noticesRequest("requestNoticeOtp", {
            id: client.id,
            body: { username: username.trim() },
            signal,
          }),
    (result) => {
      if ("challenge" in result) {
        setChallenge(result.challenge);
        setOtp("");
      } else connected();
    },
  );
  const expired = write.error instanceof NoticesError && write.error.code === "invalid_challenge";
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) close();
      }}
    >
      <DialogContent finalFocus={finalFocus} className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>{challenge ? "Verify GST connection" : "Connect GST"}</DialogTitle>
          <DialogDescription>
            {client.name} · {client.gstin}
            <br />
            {challenge
              ? "Enter the six-digit code sent to the mobile and email registered with GST."
              : "Use the client's GST portal username to request an OTP."}
          </DialogDescription>
        </DialogHeader>
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            write.act();
          }}
        >
          {challenge ? (
            <div className="space-y-2">
              <Label htmlFor="notice-otp">Verification code</Label>
              <Input
                id="notice-otp"
                autoFocus
                required
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                maxLength={6}
                value={otp}
                disabled={write.isPending}
                onChange={(e) => setOtp(e.target.value.replace(/\D/g, ""))}
              />
            </div>
          ) : (
            <div className="space-y-2">
              <Label htmlFor="notice-username">GST username</Label>
              <Input
                id="notice-username"
                autoFocus
                required
                maxLength={100}
                autoComplete="username"
                value={username}
                disabled={write.isPending}
                onChange={(e) => setUsername(e.target.value)}
              />
            </div>
          )}
          {write.error && (
            <p role="alert" className="text-sm text-destructive">
              {write.error.message}
            </p>
          )}
          <Button
            type="submit"
            className="w-full"
            disabled={
              write.isPending || expired || (challenge ? otp.length !== 6 : !username.trim())
            }
          >
            {write.isPending ? "Please wait…" : challenge ? "Verify and check notices" : "Send OTP"}
          </Button>
          {challenge && (
            <Button
              type="button"
              variant="ghost"
              className="w-full"
              disabled={write.isPending}
              onClick={() => {
                setChallenge(null);
                setOtp("");
                write.reset();
              }}
            >
              Request a new code
            </Button>
          )}
        </form>
      </DialogContent>
    </Dialog>
  );
}
