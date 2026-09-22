import { useEffect, useState } from "react";
import { Link, Outlet, useLocation, useNavigate } from "react-router-dom";
import {
  Building2,
  ChevronRight,
  FileSpreadsheet,
  FileText,
  Inbox,
  Landmark,
  PanelLeft,
  Users,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { NativeSelect } from "@/components/ui/native-select";
import { clientName as sampleClientName } from "@/data/sales";
const titles: Record<string, string> = {
  "/sales": "Sales & GSTR-1",
  "/sales/register": "Sales register",
  "/sales/upload": "Add sales bills",
  "/sales/uploads": "Uploads",
  "/sales/checks": "Month checks",
  "/purchases": "Purchases & ITC",
  "/purchases/register": "Source register",
  "/sales/sections/b2b": "B2B",
  "/sales/sections/b2cl": "B2C Large",
  "/sales/sections/b2cs": "B2C Others",
  "/sales/sections/cdnr": "Credit and debit notes",
  "/sales/sections/exp": "Exports",
  "/sales/sections/sez": "SEZ supplies",
  "/sales/sections/hsn": "HSN summary",
  "/sales/sections/documents": "Documents issued",
};

export function Shell({
  live,
  firm,
}: {
  firm?: { name: string; org: string };
  live?: {
    client: { id: number; name: string };
    clients: { id: number; name: string }[];
    user: { name: string; org: string };
    base: string;
    purchases: string;
  };
}) {
  const user = live?.user ?? firm;
  const clientName = live?.client.name ?? firm?.org ?? sampleClientName;
  const salesPath = live?.base ?? "/sales";
  const { pathname, search } = useLocation();
  const purchasesPath = live?.purchases;
  const inPurchases = Boolean(purchasesPath && pathname.startsWith(purchasesPath));
  const sectionPath = inPurchases ? purchasesPath! : salesPath;
  const sectionLabel = inPurchases ? "Purchases & ITC" : "Sales & GSTR-1";
  const period = live?.base.split("/")[3] ?? new URLSearchParams(search).get("period");
  const clientsPath = period ? `/clients?period=${encodeURIComponent(period)}` : "/clients";
  const navigate = useNavigate();
  const [collapsed, setCollapsed] = useState(false);
  const title = firm
    ? pathname.endsWith("/new") ? "Add client" : pathname.endsWith("/edit") ? "Edit client" : pathname.endsWith("/import") ? "Import clients" : "Clients"
    : titles[live ? pathname.replace(sectionPath, inPurchases ? "/purchases" : "/sales") : pathname] ?? "Page not found";

  useEffect(() => {
    document.title = `${title} · Nila${live || firm ? "" : " preview"}`;
    const frame = requestAnimationFrame(() => {
      window.scrollTo(0, 0);
      document.getElementById("main-content")?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [pathname, title]);

  return (
    <div className="min-h-screen bg-neutral-50/70">
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50 focus:rounded-md focus:bg-white focus:px-4 focus:py-2"
      >
        Skip to content
      </a>
      <aside
        aria-label="Workspace navigation"
        className={`fixed inset-y-0 left-0 hidden flex-col border-r bg-white md:flex ${collapsed ? "w-16" : "w-56"}`}
      >
        <div
          className={`flex h-16 items-center ${collapsed ? "justify-center" : "justify-between px-6"}`}
        >
          {!collapsed && (
            <Link
              to={firm ? clientsPath : salesPath}
              aria-label={firm ? "Nila clients home" : "Nila sales home"}
              className="text-2xl font-semibold tracking-tighter"
            >
              nila<span className="text-neutral-400">.</span>
            </Link>
          )}
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            aria-expanded={!collapsed}
            onClick={() => setCollapsed((value) => !value)}
          >
            <PanelLeft className="text-muted-foreground" />
          </Button>
        </div>
        <div className="px-3 pt-3">
          {live && !collapsed ? (
            <NativeSelect
              aria-label="Client"
              value={live.client.id}
              onChange={(event) =>
                navigate(
                  pathname.replace(
                    `/gst/${live.client.id}/`,
                    `/gst/${event.target.value}/`,
                  ) + search,
                )
              }
            >
              {live.clients.map((client) => (
                <option key={client.id} value={client.id}>
                  {client.name}
                </option>
              ))}
            </NativeSelect>
          ) : (
            <div
              className={`flex h-11 items-center rounded-md border text-sm font-medium ${collapsed ? "justify-center" : "gap-2.5 px-3"}`}
              title={clientName}
            >
              <Building2 className="size-4 shrink-0 text-muted-foreground" />
              {!collapsed && <span className="truncate">{clientName}</span>}
            </div>
          )}
        </div>
        <nav aria-label="Product" className="space-y-1 px-3 py-7">
          {!firm && <Link
            to={salesPath}
            aria-current={pathname.startsWith(salesPath) ? "page" : undefined}
            title={collapsed ? "Sales & GSTR-1" : undefined}
            className={`flex h-10 items-center rounded-md text-sm ${pathname.startsWith(salesPath) ? "bg-neutral-100 font-medium" : "text-muted-foreground hover:bg-muted"} ${collapsed ? "justify-center" : "gap-3 px-3"}`}
          >
            <FileText className="size-4 shrink-0" />
            {!collapsed ? (
              "Sales & GSTR-1"
            ) : (
              <span className="sr-only">Sales & GSTR-1</span>
            )}
          </Link>}
          {!live && !firm &&
            [
              { label: "Purchases & ITC", Icon: FileSpreadsheet },
              { label: "Banking", Icon: Landmark },
            ].map(({ label, Icon }) => (
              <button
                key={label}
                disabled
                title="Not included in the sales UI preview"
                className={`flex h-10 w-full cursor-not-allowed items-center rounded-md text-sm text-muted-foreground ${collapsed ? "justify-center" : "gap-3 px-3"}`}
              >
                <Icon className="size-4 shrink-0" />
                {!collapsed ? label : <span className="sr-only">{label}</span>}
              </button>
            ))}
          {live && (
            <>
              <Link
                to={live.purchases}
                aria-current={inPurchases ? "page" : undefined}
                title={collapsed ? "Purchases & ITC" : undefined}
                className={`flex h-10 items-center rounded-md text-sm ${inPurchases ? "bg-neutral-100 font-medium" : "text-muted-foreground hover:bg-muted"} ${collapsed ? "justify-center" : "gap-3 px-3"}`}
              >
                <FileSpreadsheet className="size-4" />
                {!collapsed ? (
                  "Purchases & ITC"
                ) : (
                  <span className="sr-only">Purchases & ITC</span>
                )}
              </Link>

            </>
          )}
          <div
            className={`${firm ? "pt-1" : "pt-7"} pb-2 text-[11px] font-medium uppercase tracking-widest text-muted-foreground ${collapsed ? "text-center" : "pl-3"}`}
          >
            {collapsed ? "···" : "Firm"}
          </div>
          {!live && !firm &&
            [
              { label: "Clients", Icon: Users },
              { label: "Notices", Icon: Inbox },
            ].map(({ label, Icon }) => (
              <button
                key={label}
                disabled
                title="Not included in the sales UI preview"
                className={`flex h-10 w-full cursor-not-allowed items-center rounded-md text-sm text-muted-foreground ${collapsed ? "justify-center" : "gap-3 px-3"}`}
              >
                <Icon className="size-4 shrink-0" />
                {!collapsed ? label : <span className="sr-only">{label}</span>}
              </button>
            ))}
          {(live || firm) && (
            <>
              <Link
                to={clientsPath}
                aria-current={firm ? "page" : undefined}
                className={`flex h-10 items-center gap-3 rounded-md px-3 text-sm ${firm ? "bg-neutral-100 font-medium" : "text-muted-foreground"}`}
              >
                <Users className="size-4" />
                {!collapsed ? (
                  "Clients"
                ) : (
                  <span className="sr-only">Clients</span>
                )}
              </Link>
              <a
                href="/notices"
                className="flex h-10 items-center gap-3 px-3 text-sm text-muted-foreground"
              >
                <Inbox className="size-4" />
                {!collapsed ? (
                  "Notices"
                ) : (
                  <span className="sr-only">Notices</span>
                )}
              </a>
            </>
          )}
        </nav>
        <div className="mt-auto border-t p-4">
          <div className="flex items-center gap-3">
            <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-neutral-100 text-xs font-medium">
              {user ? user.name.slice(0, 2).toUpperCase() : "DP"}
            </span>
            {!collapsed && (
              <div>
                <p className="text-xs font-medium">
                  {user?.name ?? "Demo Presenter"}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {user?.org ?? "Nila Dev CA"}
                </p>
              </div>
            )}
          </div>
        </div>
      </aside>
      <div className={collapsed ? "md:ml-16" : "md:ml-56"}>
        <header className="flex min-h-14 flex-wrap items-center justify-between gap-2 border-b bg-white/80 px-6 py-3 lg:px-10">
          <nav
            aria-label="Breadcrumb"
            className="flex items-center gap-2 text-xs text-muted-foreground"
          >
            <span>{clientName}</span>
            <ChevronRight className="size-3" />
            {firm ? (
              <><Link to={clientsPath} className="hover:text-foreground">Clients</Link>{title !== "Clients" && <><ChevronRight className="size-3" /><span className="text-foreground">{title}</span></>}</>
            ) : pathname === sectionPath ? (
              <span className="text-foreground">{title}</span>
            ) : (
              <>
                <Link to={sectionPath} className="hover:text-foreground">
                  {sectionLabel}
                </Link>
                <ChevronRight className="size-3" />
                <span className="text-foreground">{title}</span>
              </>
            )}
          </nav>
          {!live && !firm && (
            <Badge
              variant="outline"
              className="font-normal text-muted-foreground"
            >
              UI preview · sample data
            </Badge>
          )}
        </header>
        <main
          id="main-content"
          tabIndex={-1}
          className="mx-auto w-full max-w-7xl px-6 py-9 outline-none lg:px-10 lg:py-11"
        >
          <Outlet />
        </main>
      </div>
    </div>
  );
}
