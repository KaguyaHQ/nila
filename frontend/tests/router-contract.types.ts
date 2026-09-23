// Compile-only regressions: navigation must carry valid route and search facts.
import { linkOptions } from "@tanstack/react-router";

function routeContracts() {
  linkOptions({
    to: "/gst/$clientId/$period/sales/invoices/$invoiceId",
    params: { clientId: "1", period: "2026-06", invoiceId: "42" },
    search: { filter: "ready", q: "00123" },
  });
  linkOptions({
    to: "/gst/$clientId/$period/sales/invoices/$invoiceId",
    // @ts-expect-error Invoice navigation requires the invoice ID.
    params: { clientId: "1", period: "2026-06" },
  });
  // @ts-expect-error A typo is not a valid route.
  linkOptions({ to: "/notice" });
  linkOptions({
    to: "/gst/$clientId/$period/sales/register",
    params: { clientId: "1", period: "2026-06" },
    // @ts-expect-error Sales filters do not accept a purchase source.
    search: { filter: "gstr2b" },
  });
  linkOptions({
    to: "/gst/$clientId/$period/purchases/register",
    params: { clientId: "1", period: "2026-06" },
    // @ts-expect-error Purchase source names are a closed set.
    search: { source: "portal" },
  });
}
void routeContracts;
