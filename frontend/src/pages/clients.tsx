import { createContext, useContext, useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, ArrowRight, FileSpreadsheet, Pencil, Plus, Search, Upload } from "lucide-react";
import { Shell } from "@/components/workspace-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { BusinessInvitation } from "@/components/business-invitation";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ApiError } from "@/lib/sales-api";
import {
  ClientApiError,
  fetchClient,
  fetchClients,
  importClients,
  previewClients,
  saveClient,
  type ClientIdentity,
  type ClientsDirectory,
} from "@/lib/clients-api";

const Directory = createContext<ClientsDirectory | null>(null);
function useClients() {
  const value = useContext(Directory);
  if (!value) throw new Error("Clients directory is missing");
  return value;
}
const retry = (count: number, error: Error) =>
  !(error instanceof ApiError && error.status < 500) && count < 1;
const pathFor = (period: string, suffix = "") =>
  `/clients${suffix}?period=${encodeURIComponent(period)}`;

export function ClientsLayout() {
  const [params] = useSearchParams();
  const period = params.get("period");
  const query = useQuery({
    queryKey: ["clients", period],
    queryFn: ({ signal }) => fetchClients(period, signal),
    retry,
  });
  if (query.isPending)
    return (
      <main className="mx-auto max-w-7xl px-10 py-16">
        <p role="status" className="text-muted-foreground">
          Loading clients…
        </p>
      </main>
    );
  if (query.isError)
    return (
      <main className="mx-auto max-w-xl px-6 py-24">
        <h1 className="text-2xl font-semibold">Clients unavailable</h1>
        <p role="alert" className="my-4 text-muted-foreground">
          {query.error.message}
        </p>
        {query.error instanceof ApiError && query.error.status === 401 ? (
          <a href="/users/log_in" className="underline">
            Sign in
          </a>
        ) : (
          <Button onClick={() => query.refetch()}>Try again</Button>
        )}
      </main>
    );
  return (
    <Directory.Provider value={query.data}>
      <Shell firm={query.data.user} />
    </Directory.Provider>
  );
}

export function ClientsPage() {
  const data = useClients();
  const [params, setParams] = useSearchParams();
  const search = useRef<HTMLInputElement>(null);
  const query = params.get("q") ?? "";
  const needle = query.trim().toLocaleLowerCase();
  const visible = data.clients.filter((client) =>
    `${client.name} ${client.gstin ?? ""}`.toLocaleLowerCase().includes(needle),
  );
  function setSearch(value: string) {
    const next = new URLSearchParams(params);
    if (value) next.set("q", value);
    else next.delete("q");
    setParams(next, { replace: true });
  }
  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold tracking-tight">Clients</h1>
        <div className="flex gap-2">
          {data.can_edit ? (
            <>
              <Button
                variant="outline"
                nativeButton={false}
                role="link"
                render={<Link to={pathFor(data.period, "/import")} />}
              >
                <Upload /> Import Excel
              </Button>
              <Button
                nativeButton={false}
                role="link"
                render={<Link to={pathFor(data.period, "/new")} />}
              >
                <Plus /> Add client
              </Button>
            </>
          ) : (
            <>
              <Button variant="outline" disabled aria-describedby="clients-role">
                <Upload /> Import Excel
              </Button>
              <Button disabled aria-describedby="clients-role">
                <Plus /> Add client
              </Button>
            </>
          )}
        </div>
      </div>
      {!data.can_edit && (
        <p id="clients-role" className="text-sm text-muted-foreground">
          Your role allows viewing clients, not adding or editing them.
        </p>
      )}
      <div className="relative max-w-sm">
        <Search className="pointer-events-none absolute top-2.5 left-3 size-4 text-muted-foreground" />
        <Input
          data-shortcut-search
          ref={search}
          aria-label="Search clients"
          placeholder="Search name or GSTIN"
          className="pr-10 pl-9"
          value={query}
          onChange={(event) => setSearch(event.target.value)}
        />
        <kbd className="pointer-events-none absolute top-2 right-3 rounded border px-1.5 text-xs text-muted-foreground">
          /
        </kbd>
      </div>
      <section aria-label="Clients" className="overflow-hidden rounded-xl border bg-card">
        <Table>
          <TableHeader>
            <TableRow className="bg-muted/30">
              <TableHead className="pl-5">Client</TableHead>
              <TableHead>GSTIN</TableHead>
              <TableHead className="w-14">
                <span className="sr-only">Edit</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.map((client) => (
              <TableRow key={client.id}>
                <TableCell className="py-4 pl-5">
                  <Link
                    to={client.sales_path}
                    className="font-medium whitespace-normal underline-offset-4 hover:underline"
                  >
                    {client.name}
                  </Link>
                </TableCell>
                <TableCell>
                  {client.gstin || <span className="text-muted-foreground">Not provided</span>}
                </TableCell>
                <TableCell className="pr-4">
                  {data.can_edit ? (
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      nativeButton={false}
                      role="link"
                      aria-label={`Edit ${client.name}`}
                      render={<Link to={pathFor(data.period, `/${client.id}/edit`)} />}
                    >
                      <Pencil className="size-4" />
                    </Button>
                  ) : (
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      disabled
                      aria-label={`Edit ${client.name}`}
                      aria-describedby="clients-role"
                    >
                      <Pencil className="size-4" />
                    </Button>
                  )}
                </TableCell>
              </TableRow>
            ))}
            {visible.length === 0 && (
              <TableRow>
                <TableCell colSpan={3} className="py-14 text-center">
                  <p className="font-medium">
                    {data.clients.length ? "No clients match" : "No clients yet"}
                  </p>
                  <p className="mt-2 text-sm text-muted-foreground">
                    {data.clients.length
                      ? "Try another name or GSTIN."
                      : "Add a client to start their sales working."}
                  </p>
                  {query && (
                    <Button
                      variant="outline"
                      size="sm"
                      className="mt-4"
                      onClick={() => setSearch("")}
                    >
                      Clear search
                    </Button>
                  )}
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
        <p role="status" className="border-t bg-muted/20 px-5 py-3 text-sm text-muted-foreground">
          Showing {visible.length} of {data.clients.length} clients
        </p>
      </section>
    </div>
  );
}

export function ClientForm() {
  const { clientId } = useParams();
  return <ClientEditor key={clientId ?? "new"} clientId={clientId} />;
}

function ClientEditor({ clientId }: { clientId?: string }) {
  const data = useClients();
  const [loadedClient, setLoadedClient] = useState<string | undefined>();
  const query = useQuery({
    queryKey: ["client", clientId],
    queryFn: ({ signal }) => fetchClient(clientId!, signal),
    enabled: Boolean(clientId),
    retry,
  });
  useEffect(() => {
    if (query.isSuccess && !query.isFetching) setLoadedClient(clientId);
  }, [clientId, query.isSuccess, query.isFetching]);
  if (clientId && query.isError)
    return (
      <div className="space-y-4">
        <p role="alert">{query.error.message}</p>
        <Button variant="outline" onClick={() => query.refetch()}>
          Try again
        </Button>
        <Link className="ml-4 underline" to={pathFor(data.period)}>
          Back to clients
        </Link>
      </div>
    );
  if (clientId && (query.isPending || loadedClient !== clientId))
    return <p role="status">Loading client…</p>;
  return (
    <IdentityForm
      key={clientId ?? "new"}
      client={clientId ? query.data?.client : undefined}
      canEdit={data.can_edit && (!clientId || query.data?.can_edit === true)}
    />
  );
}

function IdentityForm({ client, canEdit }: { client?: ClientIdentity; canEdit: boolean }) {
  const data = useClients();
  const navigate = useNavigate();
  const cache = useQueryClient();
  const [name, setName] = useState(client?.name ?? "");
  const [gstin, setGstin] = useState(client?.gstin ?? "");
  const operation = useRef<AbortController | null>(null);
  useEffect(() => () => operation.current?.abort(), []);
  const save = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({
      controller,
      name,
      gstin,
    }: {
      controller: AbortController;
      name: string;
      gstin: string;
    }) => saveClient(client?.id, { name, gstin }, controller.signal),
    onSuccess: async (saved, { controller }) => {
      if (controller.signal.aborted) return;
      await cache.cancelQueries({ queryKey: ["client", String(saved.client.id)] });
      if (controller.signal.aborted) return;
      cache.setQueryData(["client", String(saved.client.id)], saved);
      await cache.invalidateQueries({ queryKey: ["clients"] });
      void cache.invalidateQueries({ queryKey: ["sales"] });
      void cache.invalidateQueries({ queryKey: ["purchases"] });
      if (!controller.signal.aborted) navigate(pathFor(data.period));
    },
    onSettled: (_saved, _error, { controller }) => {
      if (operation.current === controller) operation.current = null;
    },
  });
  const busy = save.isPending;
  const error = save.error;
  const fieldErrors = error instanceof ClientApiError ? error.fields : {};
  function submit(event: FormEvent) {
    event.preventDefault();
    if (!canEdit || operation.current || save.isPending) return;
    const controller = new AbortController();
    operation.current = controller;
    save.mutate({ controller, name, gstin });
  }
  return (
    <div className="mx-auto max-w-xl space-y-6">
      <div>
        <Link
          to={pathFor(data.period)}
          className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="size-4" /> Clients
        </Link>
        <h1 className="text-2xl font-semibold tracking-tight">
          {client ? "Edit client" : "Add client"}
        </h1>
      </div>
      {!canEdit && (
        <p id="client-role" className="text-sm text-muted-foreground">
          Your role allows viewing clients, not adding or editing them.
        </p>
      )}
      <form
        onSubmit={submit}
        className="space-y-5 rounded-xl border bg-card p-6"
        aria-label={client ? "Edit client" : "Add client"}
      >
        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error.message}
          </p>
        )}
        <div className="space-y-2">
          <label htmlFor="client-name" className="text-sm font-medium">
            Client name
          </label>
          <Input
            id="client-name"
            name="name"
            autoComplete="organization"
            required
            maxLength={255}
            disabled={busy || !canEdit}
            value={name}
            onChange={(event) => setName(event.target.value)}
            aria-invalid={Boolean(fieldErrors.name)}
            aria-describedby={fieldErrors.name ? "client-name-error" : undefined}
          />
          {fieldErrors.name && (
            <p id="client-name-error" className="text-sm text-destructive">
              {fieldErrors.name.join(". ")}
            </p>
          )}
        </div>
        <div className="space-y-2">
          <label htmlFor="client-gstin" className="text-sm font-medium">
            GSTIN <span className="font-normal text-muted-foreground">(optional)</span>
          </label>
          <Input
            id="client-gstin"
            name="gstin"
            autoComplete="off"
            maxLength={15}
            disabled={busy || !canEdit}
            value={gstin}
            onChange={(event) => setGstin(event.target.value.toUpperCase())}
            aria-invalid={Boolean(fieldErrors.gstin)}
            aria-describedby={fieldErrors.gstin ? "client-gstin-error" : undefined}
          />
          {fieldErrors.gstin && (
            <p id="client-gstin-error" className="text-sm text-destructive">
              {fieldErrors.gstin.join(". ")}
            </p>
          )}
        </div>
        <div className="flex justify-end gap-3">
          <Button
            type="button"
            variant="outline"
            nativeButton={false}
            role="link"
            render={<Link to={pathFor(data.period)} />}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            disabled={busy || !canEdit}
            aria-describedby={!canEdit ? "client-role" : undefined}
          >
            {busy ? "Saving…" : client ? "Save changes" : "Add client"}
          </Button>
        </div>
      </form>
      {client && (
        <a
          href={`/clients/${client.id}/edit`}
          className="inline-flex items-center gap-2 text-sm underline underline-offset-4"
        >
          GST and Tally connections <ArrowRight className="size-4" />
        </a>
      )}
      {client && data.can_manage_users && <BusinessInvitation clientId={client.id} />}
    </div>
  );
}

export function ClientsImport() {
  const data = useClients();
  const cache = useQueryClient();
  const [file, setFile] = useState<File | null>(null);
  const [validationError, setValidationError] = useState("");
  const operation = useRef<AbortController | null>(null);
  useEffect(() => () => operation.current?.abort(), []);
  const previewMutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({ file, controller }: { file: File; controller: AbortController }) =>
      previewClients(file, controller.signal),
    onSettled: (_data, _error, { controller }) => {
      if (operation.current === controller) operation.current = null;
    },
  });
  const importMutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({ token, controller }: { token: string; controller: AbortController }) =>
      importClients(token, controller.signal),
    onSuccess: (_saved, { controller }) => {
      if (controller.signal.aborted) return;
      void cache.invalidateQueries({ queryKey: ["clients"] });
      void cache.invalidateQueries({ queryKey: ["sales"] });
      void cache.invalidateQueries({ queryKey: ["purchases"] });
    },
    onSettled: (_data, _error, { controller }) => {
      if (operation.current === controller) operation.current = null;
    },
  });
  const preview = previewMutation.data;
  const result = importMutation.data;
  const busy = previewMutation.isPending || importMutation.isPending;
  const error = validationError || importMutation.error?.message || previewMutation.error?.message;
  const rows = result?.rows ?? preview?.rows ?? [];
  const hasUsername = rows.some((row) => row.gst_username);
  function selectFile(selected: File | undefined) {
    if (operation.current) return;
    previewMutation.reset();
    importMutation.reset();
    setFile(null);
    setValidationError("");
    if (!selected) return;
    if (!/\.xlsx$/i.test(selected.name)) {
      setValidationError("Choose an Excel workbook (.xlsx).");
      return;
    }
    if (!selected.size || selected.size > 2_000_000) {
      setValidationError("Choose a non-empty Excel file up to 2 MB.");
      return;
    }
    setFile(selected);
  }
  function run(save: boolean) {
    if (!data.can_edit || operation.current || busy || (save ? !preview || Boolean(result) : !file))
      return;
    const controller = new AbortController();
    operation.current = controller;
    setValidationError("");
    if (save) importMutation.mutate({ token: preview!.token, controller });
    else {
      importMutation.reset();
      previewMutation.mutate({ file: file!, controller });
    }
  }
  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <div>
        <Link
          to={pathFor(data.period)}
          className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="size-4" /> Clients
        </Link>
        <h1 className="text-2xl font-semibold tracking-tight">Import clients</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Check your Excel list before adding clients. Existing clients will not be changed.
        </p>
      </div>
      {!data.can_edit && (
        <p id="import-role" className="text-sm text-muted-foreground">
          Your role allows viewing clients, not importing them.
        </p>
      )}
      <div className="space-y-4 rounded-xl border bg-card p-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <label htmlFor="client-excel" className="text-sm font-medium">
            Client list (.xlsx)
          </label>
          <a
            href="/clients/import-template.xlsx"
            className="inline-flex items-center gap-2 text-sm underline underline-offset-4"
          >
            <FileSpreadsheet className="size-4" /> Download template
          </a>
        </div>
        <Input
          id="client-excel"
          type="file"
          accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          disabled={busy || !data.can_edit}
          onChange={(event) => selectFile(event.target.files?.[0])}
          aria-describedby="import-limits"
        />
        <p id="import-limits" className="text-sm text-muted-foreground">
          One worksheet, up to 1,000 clients and 2 MB. Include Client name, GSTIN and GST username
          columns. GSTIN and GST username may be blank.
        </p>
        <Button
          variant="outline"
          disabled={busy || !file || !data.can_edit}
          onClick={() => run(false)}
        >
          {busy && !preview ? "Reading…" : "Preview clients"}
        </Button>
      </div>
      {error && (
        <p
          role="alert"
          className="rounded-lg border border-destructive/30 px-4 py-3 text-sm text-destructive"
        >
          {error}
        </p>
      )}
      {(preview || result) && (
        <section aria-labelledby="client-import-preview" className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h2 id="client-import-preview" className="text-sm font-semibold">
              {result ? "Import results" : "Preview"}
            </h2>
            <p role="status" className="text-sm text-muted-foreground">
              {result
                ? `${result.added_count} added · ${result.skipped_count} skipped · ${result.invalid_count} invalid`
                : `${preview!.ready_count} ready to add · ${rows.filter((row) => row.status === "skip").length} skipped · ${rows.filter((row) => row.status === "invalid").length} invalid`}
            </p>
          </div>
          <div className="overflow-hidden rounded-xl border bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="pl-4">Excel row</TableHead>
                  <TableHead>Client name</TableHead>
                  <TableHead>GSTIN</TableHead>
                  {hasUsername && <TableHead>GST username</TableHead>}
                  <TableHead>Result</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((row) => (
                  <TableRow key={row.row}>
                    <TableCell className="pl-4">{row.row}</TableCell>
                    <TableCell className="max-w-64 whitespace-normal">{row.name || "—"}</TableCell>
                    <TableCell>{row.gstin || "—"}</TableCell>
                    {hasUsername && <TableCell>{row.gst_username || "—"}</TableCell>}
                    <TableCell className="max-w-sm whitespace-normal">
                      <Badge
                        variant="secondary"
                        className={
                          row.status === "invalid"
                            ? "bg-amber-50 text-amber-800"
                            : row.status === "added"
                              ? "bg-emerald-50 text-emerald-800"
                              : ""
                        }
                      >
                        {row.status === "skip"
                          ? "Skipped"
                          : row.status === "ready"
                            ? "Ready to add"
                            : row.status === "added"
                              ? "Added"
                              : "Invalid"}
                      </Badge>
                      {row.message !==
                        (row.status === "ready"
                          ? "Ready to add"
                          : row.status === "added"
                            ? "Added"
                            : "") && (
                        <p className="mt-1 text-sm text-muted-foreground">{row.message}</p>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
          <div className="flex justify-end">
            {result ? (
              <Button nativeButton={false} role="link" render={<Link to={pathFor(data.period)} />}>
                View clients <ArrowRight />
              </Button>
            ) : (
              <Button
                disabled={busy || !data.can_edit || !preview!.ready_count}
                onClick={() => run(true)}
              >
                {busy
                  ? "Saving…"
                  : `Add ${preview!.ready_count} ${preview!.ready_count === 1 ? "client" : "clients"}`}
              </Button>
            )}
          </div>
        </section>
      )}
    </div>
  );
}
