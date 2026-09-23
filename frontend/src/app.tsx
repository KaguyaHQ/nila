import { Link, Navigate, Route, Routes } from "react-router-dom";
import { KeyboardShortcuts } from "@/components/keyboard-shortcuts";
import { Button } from "@/components/ui/button";
import {
  BusinessLayout,
  BusinessInvoices,
  BusinessInvoiceEditor,
  BusinessCustomers,
  BusinessSettings,
  BusinessServices,
} from "@/pages/business";
import { Shell } from "@/components/workspace-shell";
import SalesSummary from "@/pages/sales-summary";
import SalesRegister from "@/pages/sales-register";
import SalesUpload from "@/pages/sales-upload";
import SalesUploads from "@/pages/sales-uploads";
import { LiveSalesUpload, LiveSalesUploads } from "@/pages/live-sales-uploads";
import { ClientsLayout, ClientsPage, ClientForm, ClientsImport } from "@/pages/clients";
import SalesInvoiceReview from "@/pages/sales-invoice";
import SalesSection from "@/pages/sales-section";
import SalesChecks from "@/pages/sales-checks";
import PurchaseReview from "@/pages/purchase-review";
import {
  LivePurchasesLayout,
  LivePurchasesSummary,
  LivePurchasesRegister,
} from "@/pages/live-purchases";
import { LiveSalesLayout, LiveSalesSummary, LiveSalesRegister } from "@/pages/live-sales";

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

export default function App() {
  return (
    <KeyboardShortcuts>
      <Routes>
        <Route path="business" element={<BusinessLayout />}>
          <Route index element={<Navigate to="invoices" replace />} />
          <Route path="invoices" element={<BusinessInvoices />} />
          <Route path="invoices/new" element={<BusinessInvoiceEditor />} />
          <Route path="invoices/:invoiceId" element={<BusinessInvoiceEditor />} />
          <Route path="quotations" element={<BusinessInvoices mode="quotation" />} />
          <Route path="quotations/new" element={<BusinessInvoiceEditor mode="quotation" />} />
          <Route
            path="quotations/:invoiceId"
            element={<BusinessInvoiceEditor mode="quotation" />}
          />
          <Route path="customers" element={<BusinessCustomers />} />
          <Route path="services" element={<BusinessServices />} />
          <Route path="settings" element={<BusinessSettings />} />
        </Route>
        <Route
          path="gst/:clientId/:period/sales/invoices/:invoiceId"
          element={<SalesInvoiceReview />}
        />
        <Route path="gst/:clientId/:period/purchases/review" element={<PurchaseReview />} />
        <Route path="gst/:clientId/:period/purchases/review/:itemId" element={<PurchaseReview />} />
        <Route path="gst/:clientId/:period/purchases" element={<LivePurchasesLayout />}>
          <Route index element={<LivePurchasesSummary />} />
          <Route path="register" element={<LivePurchasesRegister />} />
        </Route>
        <Route path="clients" element={<ClientsLayout />}>
          <Route index element={<ClientsPage />} />
          <Route path="new" element={<ClientForm />} />
          <Route path=":clientId/edit" element={<ClientForm />} />
          <Route path="import" element={<ClientsImport />} />
        </Route>
        <Route path="gst/:clientId/:period" element={<LiveSalesLayout />}>
          <Route path="sales" element={<LiveSalesSummary />} />
          <Route path="sales/register" element={<LiveSalesRegister />} />
          <Route path="sales/checks" element={<SalesChecks />} />
          <Route path="sales/sections/:section" element={<SalesSection />} />
          <Route path="sales/upload" element={<LiveSalesUpload />} />
          <Route path="sales/uploads" element={<LiveSalesUploads />} />
        </Route>
        {import.meta.env.DEV && (
          <Route element={<Shell />}>
            <Route index element={<Navigate to="/sales" replace />} />
            <Route path="sales" element={<SalesSummary />} />
            <Route path="sales/register" element={<SalesRegister />} />
            <Route path="sales/upload" element={<SalesUpload />} />
            <Route path="sales/uploads" element={<SalesUploads />} />
            <Route path="*" element={<NotFound />} />
          </Route>
        )}
        {!import.meta.env.DEV && (
          <Route
            path="*"
            element={
              <main className="p-10">
                <h1 className="text-2xl font-semibold">Page not found</h1>
                <a href="/clients" className="mt-4 inline-block underline">
                  Back to clients
                </a>
              </main>
            }
          />
        )}
      </Routes>
    </KeyboardShortcuts>
  );
}
