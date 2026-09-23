import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { Building2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Combobox,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
  ComboboxTrigger,
} from "@/components/ui/combobox";
import { fetchClients } from "@/lib/clients-api";

type Client = { id: number; name: string; gstin?: string | null };

// A client change must not carry another client's document IDs or search text.
export function clientDestination(pathname: string, search: string, clientId: number) {
  const match = pathname.match(/^\/gst\/\d+\/(\d{4}-\d{2})\/(sales|purchases)(.*)$/);
  if (!match) return `/clients`;
  const suffix = /^(|\/register|\/uploads|\/checks|\/upload|\/sections\/[a-z0-9]+)$/.test(match[3])
    ? match[3]
    : "";
  const source = new URLSearchParams(search);
  const params = new URLSearchParams();
  if (suffix === "/register") {
    for (const key of ["filter", "source"]) if (source.has(key)) params.set(key, source.get(key)!);
  }
  return `/gst/${clientId}/${match[1]}/${match[2]}${suffix}${params.size ? `?${params}` : ""}`;
}

export function ClientSwitcher({
  client,
  clients,
  collapsed,
  workspacePath,
}: {
  client?: Client;
  clients: Client[];
  collapsed: boolean;
  workspacePath?: string;
}) {
  const { pathname, search } = useLocation();
  const navigate = useNavigate();
  const activePath = pathname.startsWith("/gst/") ? pathname : (workspacePath ?? pathname);
  const explicitPeriod = new URLSearchParams(search).get("period");
  const period =
    activePath.match(/\/gst\/\d+\/(\d{4}-\d{2})/)?.[1] ??
    (explicitPeriod && /^\d{4}-(0[1-9]|1[0-2])$/.test(explicitPeriod) ? explicitPeriod : null);
  const [open, setOpen] = useState(false);
  const directory = useQuery({
    queryKey: ["clients", period],
    queryFn: ({ signal }) => fetchClients(period, signal),
    enabled: open,
    staleTime: 60_000,
    retry: false,
  });
  const choices: Client[] = directory.data?.clients ?? clients;
  const selected = choices.find((item) => item.id === client?.id) ?? client ?? null;
  return (
    <Combobox
      open={open}
      onOpenChange={setOpen}
      items={choices}
      value={selected}
      itemToStringLabel={(item) => `${item.name} ${item.gstin ?? ""}`}
      isItemEqualToValue={(a, b) => a.id === b.id}
      onValueChange={(item) => {
        if (item && (item.id !== client?.id || !pathname.startsWith("/gst/"))) {
          const targetPeriod = period ?? directory.data?.period;
          if (!targetPeriod) return;
          setOpen(false);
          navigate(
            clientDestination(
              activePath.startsWith("/gst/") ? activePath : `/gst/${item.id}/${targetPeriod}/sales`,
              pathname.startsWith("/gst/") ? search : "",
              item.id,
            ),
          );
        }
      }}
    >
      <ComboboxTrigger
        render={
          <Button
            variant="ghost"
            className={collapsed ? "w-full px-1" : "w-full justify-between"}
          />
        }
        aria-label={client ? `Switch client: ${client.name}` : "Select client"}
      >
        <Building2 className="shrink-0" />
        {!collapsed && (
          <span className="min-w-0 flex-1 truncate text-left">
            {client?.name ?? "Select client"}
          </span>
        )}
      </ComboboxTrigger>
      <ComboboxContent className="w-72">
        <ComboboxInput
          aria-label="Search clients"
          placeholder="Search name or GSTIN..."
          showTrigger={false}
        />
        {directory.isLoading && (
          <p role="status" className="px-3 py-2 text-xs text-muted-foreground">
            Loading clients...
          </p>
        )}
        {directory.isError && (
          <p role="alert" className="px-3 py-2 text-xs text-destructive">
            Couldn't load GSTIN search. You can still choose a client by name.
          </p>
        )}
        <ComboboxEmpty>No clients found.</ComboboxEmpty>
        <ComboboxList>
          {(item: Client) => (
            <ComboboxItem key={item.id} value={item}>
              <span>
                <span className="block">{item.name}</span>
                {item.gstin && (
                  <span className="block text-xs text-muted-foreground">{item.gstin}</span>
                )}
              </span>
            </ComboboxItem>
          )}
        </ComboboxList>
        <div className="border-t p-1">
          <Button
            variant="ghost"
            className="w-full justify-start"
            nativeButton={false}
            role="link"
            render={<Link to={period ? `/clients?period=${period}` : "/clients"} />}
            onClick={() => setOpen(false)}
          >
            View all clients
          </Button>
        </div>
      </ComboboxContent>
    </Combobox>
  );
}
