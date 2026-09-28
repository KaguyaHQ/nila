import { createLink, Link, Outlet, useLocation } from "@tanstack/react-router";
import {
  Building2,
  Inbox,
  Landmark,
  PanelLeft,
  ReceiptText,
  ShoppingBag,
  Users,
} from "lucide-react";
import { type ComponentProps, type ReactNode, useEffect, useState } from "react";
import { AccountMenu } from "@/components/account-menu";
import { ClientSwitcher } from "@/components/client-switcher";
import { ShortcutHelpButton } from "@/components/keyboard-shortcuts";
import { Badge } from "@/components/ui/badge";
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/components/ui/breadcrumb";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { WorkspaceCommand } from "@/components/workspace-command";
import { clientName as sampleClientName } from "@/data/sales";
import { urlDestination } from "@/lib/route-url";
import { useClientContext } from "@/state/client-context";

const titles: Record<string, string> = {
  "/sales": "Sales & GSTR-1",
  "/sales/register": "Sales register",
  "/sales/upload": "Add sales bills",
  "/sales/uploads": "Uploads",
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
  children,
  clients,
  settings,
  notices = false,
}: {
  settings?: string;
  notices?: boolean;
  clients?: { id: number; name: string }[];
  children?: ReactNode;
  firm?: { name: string; org: string };
  live?: {
    client: { id: number; name: string };
    clients: { id: number; name: string }[];
    user: { name: string; org: string };
    base: string;
    purchases: string;
  };
}) {
  const selected = useClientContext();
  const retained = firm && clients?.find((client) => client.id === selected?.clientId);
  if (!live && retained && selected) {
    live = {
      client: retained,
      clients: clients!,
      user: firm!,
      base: `/gst/${retained.id}/${selected.period}/sales`,
      purchases: `/gst/${retained.id}/${selected.period}/purchases`,
    };
  }
  const user = live?.user ?? firm;
  const clientName = live?.client.name ?? firm?.org ?? sampleClientName;
  const salesPath = live?.base ?? "/sales";
  const { pathname, searchStr: search } = useLocation();
  const purchasesPath = live?.purchases;
  const inPurchases = Boolean(purchasesPath && pathname.startsWith(purchasesPath));
  const sectionPath = inPurchases ? purchasesPath! : salesPath;
  const sectionLabel = inPurchases ? "Purchases & ITC" : "Sales & GSTR-1";
  const period = live?.base.split("/")[3] ?? new URLSearchParams(search).get("period");
  const clientsPath = period ? `/clients?period=${encodeURIComponent(period)}` : "/clients";
  const [collapsed, setCollapsed] = useState(
    () => localStorage.getItem("nila:rail-collapsed") === "true",
  );
  useEffect(() => {
    localStorage.setItem("nila:rail-collapsed", String(collapsed));
  }, [collapsed]);
  const title =
    (notices ? "Notices" : settings) ??
    (firm
      ? pathname.endsWith("/new")
        ? "Add client"
        : pathname.endsWith("/edit")
          ? "Edit client"
          : pathname.endsWith("/import")
            ? "Import clients"
            : "Clients"
      : (titles[
          live ? pathname.replace(sectionPath, inPurchases ? "/purchases" : "/sales") : pathname
        ] ?? (pathname.includes("/sales/uploads/") ? "Upload results" : "Page not found")));

  useEffect(() => {
    document.title = `${title} · Nila${live || firm ? "" : " preview"}`;
    const frame = requestAnimationFrame(() => {
      if (!pathname.endsWith("/sales/register")) window.scrollTo(0, 0);
      const main = document.getElementById("main-content");
      if (!main?.contains(document.activeElement)) main?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [pathname, title]);

  const navigation = (collapsed: boolean) => (
    <>
      <div
        className={`flex h-16 items-center ${collapsed ? "justify-center" : "justify-between px-6"}`}
      >
        {!collapsed && (
          <Link
            {...urlDestination(firm ? clientsPath : salesPath)}
            aria-label={firm ? "Nila clients home" : "Nila sales home"}
            className="font-brand text-[32px] font-semibold tracking-tight"
          >
            nila
          </Link>
        )}
        <Button
          variant="ghost"
          size="icon-sm"
          className="hidden md:inline-flex"
          aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
          aria-expanded={!collapsed}
          onClick={() => setCollapsed((value) => !value)}
        >
          <PanelLeft className="text-muted-foreground" />
        </Button>
      </div>
      <div className="px-3 pt-3">
        {live || (firm && clients) ? (
          <ClientSwitcher
            client={live?.client}
            clients={live?.clients ?? clients!}
            collapsed={collapsed}
            workspacePath={firm && selected?.section === "purchases" ? live?.purchases : live?.base}
          />
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
        {(!firm || live) && (
          <NavigationLink
            collapsed={collapsed}
            {...urlDestination(salesPath)}
            aria-current={pathname.startsWith(salesPath) ? "page" : undefined}
            label="Sales & GSTR-1"
            className={`flex h-10 items-center rounded-md text-sm ${pathname.startsWith(salesPath) ? "bg-neutral-100 font-medium" : "text-muted-foreground hover:bg-muted"} ${collapsed ? "justify-center" : "gap-3 px-3"}`}
          >
            <ReceiptText className="size-4 shrink-0" />
            {!collapsed ? "Sales & GSTR-1" : <span className="sr-only">Sales & GSTR-1</span>}
          </NavigationLink>
        )}
        {!live &&
          !firm &&
          [
            { label: "Purchases & ITC", Icon: ShoppingBag },
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
            <NavigationLink
              collapsed={collapsed}
              {...urlDestination(live.purchases)}
              aria-current={inPurchases ? "page" : undefined}
              label="Purchases & ITC"
              className={`flex h-10 items-center rounded-md text-sm ${inPurchases ? "bg-neutral-100 font-medium" : "text-muted-foreground hover:bg-muted"} ${collapsed ? "justify-center" : "gap-3 px-3"}`}
            >
              <ShoppingBag className="size-4" />
              {!collapsed ? "Purchases & ITC" : <span className="sr-only">Purchases & ITC</span>}
            </NavigationLink>
          </>
        )}
        <div
          className={`${firm && !live ? "pt-1" : "pt-7"} pb-2 text-[11px] font-medium uppercase tracking-widest text-muted-foreground ${collapsed ? "text-center" : "pl-3"}`}
        >
          {collapsed ? "···" : "Firm"}
        </div>
        {!live &&
          !firm &&
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
            <NavigationLink
              collapsed={collapsed}
              to="/clients"
              search={{ period: period ?? undefined }}
              label="Clients"
              aria-current={firm && !settings && !notices ? "page" : undefined}
              className={`flex h-10 items-center gap-3 rounded-md px-3 text-sm ${firm && !settings && !notices ? "bg-neutral-100 font-medium" : "text-muted-foreground"}`}
            >
              <Users className="size-4" />
              {!collapsed ? "Clients" : <span className="sr-only">Clients</span>}
            </NavigationLink>
            <NavigationLink
              collapsed={collapsed}
              label="Notices"
              to="/notices"
              aria-current={notices ? "page" : undefined}
              className={`flex h-10 items-center gap-3 rounded-md px-3 text-sm ${notices ? "bg-muted font-medium" : "text-muted-foreground hover:bg-muted"}`}
            >
              <Inbox className="size-4" />
              {!collapsed ? "Notices" : <span className="sr-only">Notices</span>}
            </NavigationLink>
          </>
        )}
      </nav>
      <div className="mt-auto border-t p-3">
        {user && <AccountMenu user={user} collapsed={collapsed} />}
      </div>
    </>
  );

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
        {navigation(collapsed)}
      </aside>
      <div className={collapsed ? "md:ml-16" : "md:ml-56"}>
        <header className="flex min-h-14 flex-wrap items-center justify-between gap-2 border-b bg-white/80 px-6 py-3 lg:px-10">
          <Breadcrumb aria-label="Breadcrumb">
            <BreadcrumbList className="gap-2 text-xs [&>[data-slot=breadcrumb-separator]>svg]:size-3">
              <BreadcrumbItem>{firm?.org ?? clientName}</BreadcrumbItem>
              <BreadcrumbSeparator />
              {notices ? (
                <BreadcrumbItem>
                  <BreadcrumbPage>Notices</BreadcrumbPage>
                </BreadcrumbItem>
              ) : settings ? (
                <>
                  <BreadcrumbItem>
                    <BreadcrumbLink
                      render={<Link to="/settings/$section" params={{ section: "profile" }} />}
                    >
                      Settings
                    </BreadcrumbLink>
                  </BreadcrumbItem>
                  <BreadcrumbSeparator />
                  <BreadcrumbItem>
                    <BreadcrumbPage>{settings}</BreadcrumbPage>
                  </BreadcrumbItem>
                </>
              ) : firm ? (
                <>
                  <BreadcrumbItem>
                    <BreadcrumbLink
                      render={<Link {...urlDestination(clientsPath)} />}
                      aria-current={title === "Clients" ? "page" : undefined}
                    >
                      Clients
                    </BreadcrumbLink>
                  </BreadcrumbItem>
                  {title !== "Clients" && (
                    <>
                      <BreadcrumbSeparator />
                      <BreadcrumbItem>
                        <BreadcrumbPage>{title}</BreadcrumbPage>
                      </BreadcrumbItem>
                    </>
                  )}
                </>
              ) : pathname === sectionPath ? (
                <BreadcrumbItem>
                  <BreadcrumbPage>{title}</BreadcrumbPage>
                </BreadcrumbItem>
              ) : (
                <>
                  <BreadcrumbItem>
                    <BreadcrumbLink render={<Link {...urlDestination(sectionPath)} />}>
                      {sectionLabel}
                    </BreadcrumbLink>
                  </BreadcrumbItem>
                  <BreadcrumbSeparator />
                  <BreadcrumbItem>
                    <BreadcrumbPage>{title}</BreadcrumbPage>
                  </BreadcrumbItem>
                </>
              )}
            </BreadcrumbList>
          </Breadcrumb>
          {(live || firm) && (
            <div className="ml-auto flex items-center gap-1">
              <WorkspaceCommand live={live} period={period} />
              <ShortcutHelpButton />
            </div>
          )}
          {!live && !firm && (
            <Badge variant="outline" className="font-normal text-muted-foreground">
              UI preview · sample data
            </Badge>
          )}
        </header>
        <main
          id="main-content"
          tabIndex={-1}
          className="mx-auto w-full max-w-7xl px-6 py-9 outline-none lg:px-10 lg:py-11"
        >
          {children ?? <Outlet />}
        </main>
      </div>
    </div>
  );
}

const NavigationLink = createLink(function NavigationAnchor({
  collapsed,
  label,
  children,
  ...props
}: ComponentProps<"a"> & { collapsed: boolean; label: string }) {
  if (!collapsed) return <a {...props}>{children}</a>;
  return (
    <Tooltip>
      <TooltipTrigger render={<a {...props} />}>{children}</TooltipTrigger>
      <TooltipContent side="right">{label}</TooltipContent>
    </Tooltip>
  );
});
