import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import {
  Building2,
  CalendarDays,
  FileSpreadsheet,
  FileText,
  Search,
  Upload,
  Users,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Kbd, KbdGroup } from "@/components/ui/kbd";
import { navigationShortcutBlocked } from "@/components/keyboard-shortcuts";
import { fetchClients } from "@/lib/clients-api";
import { clientDestination } from "@/components/client-switcher";

type Client = { id: number; name: string; gstin?: string | null };
type Props = {
  live?: { client: Client; clients: Client[]; base: string; purchases: string };
  period?: string | null;
};

export function WorkspaceCommand({ live, period: selectedPeriod }: Props) {
  const { pathname, search: routeSearch } = useLocation();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const opener = useRef<HTMLElement | null>(null);
  const period = selectedPeriod ?? live?.base.split("/")[3] ?? null;
  const directory = useQuery({
    queryKey: ["clients", period],
    queryFn: ({ signal }) => fetchClients(period, signal),
    enabled: open,
    retry: false,
  });
  const clients = directory.data?.clients ?? live?.clients ?? [];
  const activePeriod = period ?? directory.data?.period;
  const modifier = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘" : "Ctrl";

  function show(button?: HTMLElement) {
    opener.current =
      button ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    setSearch("");
    setOpen(true);
  }
  useEffect(() => {
    function keydown(event: KeyboardEvent) {
      if (
        !(event.ctrlKey || event.metaKey) ||
        event.key.toLowerCase() !== "k" ||
        event.altKey ||
        event.shiftKey ||
        navigationShortcutBlocked(event)
      )
        return;
      event.preventDefault();
      show();
    }
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, []);
  useEffect(() => {
    setOpen(false);
  }, [pathname]);
  function go(path: string) {
    setOpen(false);
    navigate(path);
  }

  const area = pathname.includes("/purchases") ? "purchases" : "sales";
  const destination = (clientId: number, targetPeriod: string) =>
    live && activePeriod
      ? clientDestination(pathname, routeSearch, clientId).replace(
          `/${activePeriod}/`,
          `/${targetPeriod}/`,
        )
      : `/gst/${clientId}/${targetPeriod}/${area}`;
  const year = search.match(/\b(\d{4})\b/)?.[1] ?? activePeriod?.slice(0, 4);
  const currentMonth = new Date().toISOString().slice(0, 7);
  const periods =
    year && activePeriod
      ? Array.from({ length: 12 }, (_, index) => {
          const value = `${year}-${String(index + 1).padStart(2, "0")}`;
          return {
            value,
            label: new Date(`${value}-01T12:00:00Z`).toLocaleDateString("en-IN", {
              month: "long",
              year: "numeric",
              timeZone: "UTC",
            }),
          };
        }).filter((month) => month.value >= "2017-07" && month.value <= currentMonth)
      : [];
  const pages = [
    ...(live
      ? [
          {
            label: "Sales & GSTR-1",
            path: live.base,
            Icon: FileText,
            keywords: ["overview", "working"],
          },
          {
            label: "Sales register",
            path: `${live.base}/register`,
            Icon: FileText,
            keywords: ["invoices", "bills"],
          },
          {
            label: "Add sales bills",
            path: `${live.base}/upload`,
            Icon: Upload,
            keywords: ["upload", "pdf"],
          },
          {
            label: "Sales uploads",
            path: `${live.base}/uploads`,
            Icon: Upload,
            keywords: ["history"],
          },
          {
            label: "Purchases & ITC",
            path: live.purchases,
            Icon: FileSpreadsheet,
            keywords: ["overview", "reconciliation"],
          },
          {
            label: "GSTR-2B register",
            path: `${live.purchases}/register?source=gstr2b`,
            Icon: FileSpreadsheet,
            keywords: ["purchase", "portal"],
          },
        ]
      : []),
    {
      label: "Clients",
      path: activePeriod ? `/clients?period=${activePeriod}` : "/clients",
      Icon: Users,
      keywords: ["directory"],
    },
  ];

  return (
    <>
      <Button
        variant="outline"
        size="sm"
        aria-label="Go to page or client"
        onClick={(event) => show(event.currentTarget)}
      >
        <Search />
        <span className="hidden sm:inline">Go to…</span>
        <KbdGroup className="hidden sm:inline-flex">
          <Kbd>{modifier}</Kbd>
          <Kbd>K</Kbd>
        </KbdGroup>
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent
          finalFocus={opener}
          showCloseButton={false}
          className="overflow-hidden p-0 sm:max-w-lg"
        >
          <DialogHeader className="sr-only">
            <DialogTitle>Go to…</DialogTitle>
            <DialogDescription>Search pages, clients or a month.</DialogDescription>
          </DialogHeader>
          <Command>
            <CommandInput
              aria-label="Search pages, clients or a month"
              placeholder="Search pages, clients or a month…"
              value={search}
              onValueChange={setSearch}
            />
            <CommandList className="max-h-[min(24rem,65dvh)]">
              <CommandEmpty>No results found.</CommandEmpty>
              <CommandGroup heading="Pages">
                {pages.map(({ label, path, Icon, keywords }) => (
                  <CommandItem
                    key={path}
                    value={label}
                    keywords={keywords}
                    onSelect={() => go(path)}
                  >
                    <Icon />
                    {label}
                  </CommandItem>
                ))}
              </CommandGroup>
              {live && (
                <CommandGroup heading="Months">
                  {periods.map((month) => (
                    <CommandItem
                      key={month.value}
                      value={month.label}
                      keywords={[month.value]}
                      onSelect={() => go(destination(live.client.id, month.value))}
                    >
                      <CalendarDays />
                      {month.label}
                    </CommandItem>
                  ))}
                </CommandGroup>
              )}
              {activePeriod && clients.length > 0 && (
                <CommandGroup heading="Clients">
                  {clients.map((client) => (
                    <CommandItem
                      key={client.id}
                      value={`client-${client.id}`}
                      keywords={[client.name, client.gstin ?? ""]}
                      onSelect={() => go(destination(client.id, activePeriod))}
                    >
                      <Building2 />
                      <span className="min-w-0 truncate">{client.name}</span>
                      {client.gstin && (
                        <span className="ml-auto text-xs text-muted-foreground">
                          {client.gstin}
                        </span>
                      )}
                    </CommandItem>
                  ))}
                </CommandGroup>
              )}
            </CommandList>
          </Command>
          {directory.isFetching && (
            <p role="status" className="px-3 pb-2 text-xs text-muted-foreground">
              Loading clients…
            </p>
          )}
          {directory.isError && (
            <div className="flex items-center justify-between gap-2 px-3 pb-2 text-xs text-muted-foreground">
              <p role="alert">Couldn’t load the client directory.</p>
              <Button variant="ghost" size="xs" onClick={() => directory.refetch()}>
                Try again
              </Button>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
