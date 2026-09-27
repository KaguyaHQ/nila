import { SalesUploadResult } from "@/pages/sales-upload-result";
import { KeyboardShortcuts } from "@/components/keyboard-shortcuts";
import { Button } from "@/components/ui/button";
import { Shell } from "@/components/workspace-shell";
import {
  businessSearch,
  clientsSearch,
  noticesSearch,
  parseSearch,
  purchaseSearch,
  reviewSearch,
  salesSearch,
  settingsSearch,
  stringifySearch,
} from "@/lib/route-search";
import {
  BusinessCustomers,
  BusinessInvoiceEditor,
  BusinessInvoices,
  BusinessIndex,
  BusinessLayout,
  BusinessServices,
  BusinessSettings,
} from "@/pages/business";
import { ClientForm, ClientsImport, ClientsLayout, ClientsPage } from "@/pages/clients";
import {
  LivePurchasesLayout,
  LivePurchasesRegister,
  LivePurchasesSummary,
} from "@/pages/live-purchases";
import { LiveSalesLayout, LiveSalesRegister, LiveSalesSummary } from "@/pages/live-sales";
import { LiveSalesUpload, LiveSalesUploads } from "@/pages/live-sales-uploads";
import NoticesPage from "@/pages/notices";
import PurchaseReview from "@/pages/purchase-review";
import SalesChecks from "@/pages/sales-checks";
import SalesInvoiceReview from "@/pages/sales-invoice";
import SalesRegister from "@/pages/sales-register";
import SalesSection from "@/pages/sales-section";
import SalesSummary from "@/pages/sales-summary";
import SalesUpload from "@/pages/sales-upload";
import SalesUploads from "@/pages/sales-uploads";
import SettingsPage from "@/pages/settings";
import { ClientContextProvider } from "@/state/client-context";
import {
  createRootRoute,
  createRoute,
  createRouter,
  Link,
  Navigate,
  Outlet,
  RouterProvider,
} from "@tanstack/react-router";

function NotFound() {
  return (
    <div className="py-12">
      <h1 className="text-2xl font-semibold">Page not found</h1>
      <p className="mt-3 text-sm text-muted-foreground">
        This sales preview includes the summary, register, and PDF uploads.
      </p>
      <Button className="mt-6" nativeButton={false} role="link" render={<Link to="/sales" />}>
        {" "}
        Back to sales summary
      </Button>
    </div>
  );
}

function RootLayout() {
  return (
    <ClientContextProvider>
      <KeyboardShortcuts>
        <Outlet />
      </KeyboardShortcuts>
    </ClientContextProvider>
  );
}
const root = createRootRoute({
  component: RootLayout,
  notFoundComponent: () =>
    import.meta.env.DEV ? (
      <Shell>
        <NotFound />
      </Shell>
    ) : (
      <main className="p-10">
        <h1 className="text-2xl font-semibold">Page not found</h1>
        <a href="/app/clients" className="mt-4 inline-block underline">
          Back to clients
        </a>
      </main>
    ),
});
const notices = createRoute({
  getParentRoute: () => root,
  path: "notices",
  validateSearch: noticesSearch,
  component: NoticesPage,
});
const notice = createRoute({
  getParentRoute: () => root,
  path: "notices/$noticeId",
  validateSearch: noticesSearch,
  component: NoticesPage,
});
const settingsIndex = createRoute({
  getParentRoute: () => root,
  path: "settings",
  component: () => <Navigate to="/settings/$section" params={{ section: "profile" }} replace />,
});
const settings = createRoute({
  getParentRoute: () => root,
  path: "settings/$section",
  validateSearch: settingsSearch,
  component: SettingsPage,
});
const business = createRoute({
  getParentRoute: () => root,
  path: "business/$businessId",
  component: BusinessLayout,
});
const businessIndex = createRoute({
  getParentRoute: () => root,
  path: "business",
  component: BusinessIndex,
});
const businessHome = createRoute({
  getParentRoute: () => business,
  path: "/",
  component: () => (
    <Navigate
      to="/business/$businessId/invoices"
      params={{ businessId: business.useParams().businessId }}
      replace
    />
  ),
});
const businessInvoices = createRoute({
  getParentRoute: () => business,
  path: "invoices",
  component: BusinessInvoices,
});
const businessInvoiceNew = createRoute({
  getParentRoute: () => business,
  path: "invoices/new",
  validateSearch: businessSearch,
  component: BusinessInvoiceEditor,
});
const businessInvoice = createRoute({
  getParentRoute: () => business,
  path: "invoices/$invoiceId",
  component: BusinessInvoiceEditor,
});
const businessQuotations = createRoute({
  getParentRoute: () => business,
  path: "quotations",
  component: () => <BusinessInvoices mode="quotation" />,
});
const businessQuotationNew = createRoute({
  getParentRoute: () => business,
  path: "quotations/new",
  component: () => <BusinessInvoiceEditor mode="quotation" />,
});
const businessQuotation = createRoute({
  getParentRoute: () => business,
  path: "quotations/$invoiceId",
  component: () => <BusinessInvoiceEditor mode="quotation" />,
});
const businessCustomers = createRoute({
  getParentRoute: () => business,
  path: "customers",
  component: BusinessCustomers,
});
const businessServices = createRoute({
  getParentRoute: () => business,
  path: "services",
  component: BusinessServices,
});
const businessSettings = createRoute({
  getParentRoute: () => business,
  path: "settings",
  component: () => (
    <Navigate
      to="/business/$businessId/settings/$section"
      params={{ businessId: business.useParams().businessId, section: "business" }}
      replace
    />
  ),
});
const businessSettingsSection = createRoute({
  getParentRoute: () => business,
  path: "settings/$section",
  component: BusinessSettings,
});
const invoice = createRoute({
  getParentRoute: () => root,
  path: "gst/$clientId/$period/sales/invoices/$invoiceId",
  validateSearch: salesSearch,
  component: SalesInvoiceReview,
});
const purchaseReview = createRoute({
  getParentRoute: () => root,
  path: "gst/$clientId/$period/purchases/review",
  validateSearch: reviewSearch,
  component: PurchaseReview,
});
const purchaseReviewItem = createRoute({
  getParentRoute: () => root,
  path: "gst/$clientId/$period/purchases/review/$itemId",
  validateSearch: reviewSearch,
  component: PurchaseReview,
});
const purchases = createRoute({
  getParentRoute: () => root,
  path: "gst/$clientId/$period/purchases",
  validateSearch: purchaseSearch,
  component: LivePurchasesLayout,
});
const purchasesIndex = createRoute({
  getParentRoute: () => purchases,
  path: "/",
  component: LivePurchasesSummary,
});
const purchasesRegister = createRoute({
  getParentRoute: () => purchases,
  path: "register",
  component: LivePurchasesRegister,
});
const clients = createRoute({
  getParentRoute: () => root,
  path: "clients",
  validateSearch: clientsSearch,
  component: ClientsLayout,
});
const clientsIndex = createRoute({
  getParentRoute: () => clients,
  path: "/",
  component: ClientsPage,
});
const clientNew = createRoute({
  getParentRoute: () => clients,
  path: "new",
  component: ClientForm,
});
const clientEdit = createRoute({
  getParentRoute: () => clients,
  path: "$clientId/edit",
  component: ClientForm,
});
const clientsImport = createRoute({
  getParentRoute: () => clients,
  path: "import",
  component: ClientsImport,
});
const sales = createRoute({
  getParentRoute: () => root,
  path: "gst/$clientId/$period",
  validateSearch: salesSearch,
  component: LiveSalesLayout,
});
const salesIndex = createRoute({
  getParentRoute: () => sales,
  path: "sales",
  component: LiveSalesSummary,
});
const salesRegister = createRoute({
  getParentRoute: () => sales,
  path: "sales/register",
  component: LiveSalesRegister,
});
const salesChecks = createRoute({
  getParentRoute: () => sales,
  path: "sales/checks",
  component: SalesChecks,
});
const salesSection = createRoute({
  getParentRoute: () => sales,
  path: "sales/sections/$section",
  component: SalesSection,
});
const salesUpload = createRoute({
  getParentRoute: () => sales,
  path: "sales/upload",
  component: LiveSalesUpload,
});
const salesUploads = createRoute({
  getParentRoute: () => sales,
  path: "sales/uploads",
  component: LiveSalesUploads,
});
const salesUploadResult = createRoute({
  getParentRoute: () => sales,
  path: "sales/uploads/$batchRef",
  component: SalesUploadResult,
});
const preview = createRoute({ getParentRoute: () => root, id: "preview", component: Shell });
const previewIndex = createRoute({
  getParentRoute: () => preview,
  path: "/",
  component: () => <Navigate to="/sales" replace />,
});
const previewSales = createRoute({
  getParentRoute: () => preview,
  path: "sales",
  component: SalesSummary,
});
const previewRegister = createRoute({
  getParentRoute: () => preview,
  path: "sales/register",
  validateSearch: salesSearch,
  component: SalesRegister,
});
const previewUpload = createRoute({
  getParentRoute: () => preview,
  path: "sales/upload",
  component: SalesUpload,
});
const previewUploads = createRoute({
  getParentRoute: () => preview,
  path: "sales/uploads",
  component: SalesUploads,
});
const routeTree = root.addChildren([
  notices,
  notice,
  settingsIndex,
  settings,
  businessIndex,
  business.addChildren([
    businessHome,
    businessInvoices,
    businessInvoiceNew,
    businessInvoice,
    businessQuotations,
    businessQuotationNew,
    businessQuotation,
    businessCustomers,
    businessServices,
    businessSettings,
    businessSettingsSection,
  ]),
  invoice,
  purchaseReview,
  purchaseReviewItem,
  purchases.addChildren([purchasesIndex, purchasesRegister]),
  clients.addChildren([clientsIndex, clientNew, clientEdit, clientsImport]),
  sales.addChildren([
    salesIndex,
    salesRegister,
    salesChecks,
    salesSection,
    salesUpload,
    salesUploads,
    salesUploadResult,
  ]),
  ...(import.meta.env.DEV
    ? [
        preview.addChildren([
          previewIndex,
          previewSales,
          previewRegister,
          previewUpload,
          previewUploads,
        ]),
      ]
    : []),
]);
export const router = createRouter({
  routeTree,
  basepath:
    location.pathname === "/app" || location.pathname.startsWith("/app/") ? "/app" : undefined,
  parseSearch,
  stringifySearch,
  defaultPreload: false,
});
declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
export default function App() {
  return <RouterProvider router={router} />;
}
