import { expect, type Page, test } from "@playwright/test";
import { readFileSync } from "node:fs";
import type {
  BusinessBootstrap,
  BusinessCustomerAddress,
  BusinessInvoice,
} from "../src/lib/business-api";
import { chooseSelect } from "./select-field";

const bootstrap: BusinessBootstrap = {
  services: [],
  business: { id: 1, address: "Chennai", name: "Breeze Services", gstin: "33AABCT3518Q1ZF" },
  profile: {
    legal_name: "Breeze Services",
    address: "Chennai",
    state_code: "33",
    phone: null,
    email: null,
    has_logo: false,
    has_signature: false,
    quotation_number_style: "nila",
    invoice_number_style: "nila",
    domestic_services_only: false,
    domestic_goods_and_services_only: false,
    e_invoice_not_applicable: false,
  },
  customers: [{ id: 4, name: "Harbour Labs", gstin: null, address: "Chennai", state_code: "33" }],
  customer_addresses: [],
  invoices: [],
  quotation_numbering: {
    financial_year: 2026,
    style: "nila",
    next_quotation_number: "QT/2627/0001",
    next_number: 1,
    editable: true,
  },
  invoice_numbering: {
    financial_year: 2026,
    style: "nila",
    next_number: 1,
    editable: true,
  },
  states: [
    { code: "33", name: "Tamil Nadu" },
    { code: "29", name: "Karnataka" },
    { code: "34", name: "Puducherry" },
  ],
};
const invoice: BusinessInvoice = {
  cancelled_at: null,
  cancelled_by_id: null,
  cancellation_reason: null,
  original_invoice_id: null,
  converted_invoice_id: null,
  valid_until: null,
  purchase_order_number: null,
  purchase_order_date: null,
  delivery_address: null,
  delivery_state_code: null,
  billing_address_id: null,
  shipping_address_id: null,
  subject: null,
  revised_from_id: null,
  snapshot: {},
  issued_at: null,
  sent_on: null,
  inserted_at: "2026-09-22T10:00:00Z",
  id: 9,
  number: null,
  status: "draft",
  document_type: "invoice",
  customer_id: 4,
  invoice_date: "2026-09-22",
  due_date: "",
  place_of_supply: "33",
  lines: [
    { description: "Consulting", sac: "998313", quantity: "1", unit_price: "1000", gst_rate: "18" },
  ],
  notes: "",
  totals: {
    taxable_paise: 100000,
    cgst_paise: 9000,
    sgst_paise: 9000,
    igst_paise: 0,
    total_paise: 118000,
  },
};
function previewPdf(text = "Draft invoice") {
  const stream = `BT /F1 18 Tf 48 760 Td (${text.replace(/[()\\]/g, " ")}) Tj ET`;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
  ];
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(pdf.length);
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const start = pdf.length;
  pdf += `xref\n0 6\n0000000000 65535 f \n${offsets
    .slice(1)
    .map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`)
    .join("")}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF`;
  return Buffer.from(pdf);
}
async function setup(page: Page) {
  await page.route(/\/api\/business\/workspaces$/, (route) =>
    route.fulfill({ json: { businesses: [{ id: 1, name: "Breeze Services", gstin: "33AABCT3518Q1ZF" }], ca_workspace: { available: false } } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/calculate$/, (route) =>
    route.fulfill({
      json: {
        totals: invoice.totals,
        lines: [{ taxable_paise: 100000, cgst_paise: 9000, sgst_paise: 9000, igst_paise: 0 }],
      },
    }),
  );
  await page.route(/\/api\/business\/1\/invoices\/preview$/, (route) =>
    route.fulfill({ contentType: "application/pdf", body: previewPdf() }),
  );
  await page.route(/\/api\/business\/1\/invoices\/\d+\/pdf$/, (route) =>
    route.fulfill({ contentType: "application/pdf", body: previewPdf("Issued invoice") }),
  );
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) => route.fulfill({ json: bootstrap }));
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "business-csrf";
      document.head.append(meta);
    }),
  );
}
async function chooseCustomer(page: Page, name: string) {
  await page.locator("#business-customer").click();
  await page.getByRole("combobox", { name: "Search customers" }).fill(name);
  await page.getByRole("option", { name, exact: true }).click();
}

test("one login opens two businesses without mixing their invoices", async ({ page }) => {
  await setup(page);
  await page.unroute(/\/api\/business\/workspaces$/);
  await page.route(/\/api\/business\/workspaces$/, (route) =>
    route.fulfill({ json: {
      businesses: [
        { id: 1, name: "Breeze Services", gstin: "33AABCT3518Q1ZF" },
        { id: 2, name: "Caltech", gstin: "33AABCT3518Q1ZG" },
      ],
      ca_workspace: { available: false },
    } }),
  );
  await page.route(/\/api\/business\/2\/bootstrap$/, (route) =>
    route.fulfill({ json: {
      ...bootstrap,
      business: { ...bootstrap.business, id: 2, name: "Caltech" },
      invoices: [{ ...invoice, id: 21, number: "CAL-21" }],
    } }),
  );

  await page.goto("/app/business");
  await page.getByRole("link", { name: /Caltech/ }).click();
  await expect(page).toHaveURL(/\/app\/business\/2\/invoices$/);
  await expect(page.getByText("CAL-21")).toBeVisible();
  await page.getByRole("button", { name: "Business" }).click();
  await page.getByRole("menuitem", { name: "Breeze Services" }).click();
  await expect(page).toHaveURL(/\/app\/business\/1\/invoices$/);
  await expect(page.getByText("CAL-21")).toHaveCount(0);
});

test("workspace switcher adds a business without leaving the app", async ({ page }, testInfo) => {
  await setup(page);
  let submitted: unknown;
  await page.unroute(/\/api\/business\/workspaces$/);
  await page.route(/\/api\/business\/workspaces$/, (route) => {
    if (route.request().method() === "POST") {
      submitted = route.request().postDataJSON();
      return route.fulfill({ status: 201, json: { business: { id: 3, name: "Caltech", gstin: "27AAPFU0939F1ZV" } } });
    }
    return route.fulfill({ json: { businesses: [{ id: 1, name: "Breeze Services", gstin: "33AABCT3518Q1ZF" }], ca_workspace: { available: false } } });
  });
  await page.route(/\/api\/business\/3\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, business: { ...bootstrap.business, id: 3, name: "Caltech", gstin: "27AAPFU0939F1ZV", address: null }, profile: { ...bootstrap.profile, address: null } } }),
  );
  await page.goto("/app/business/1/invoices");
  await page.getByRole("button", { name: "Business" }).click();
  await page.getByRole("menuitem", { name: "Add business" }).click();
  const dialog = page.getByRole("dialog", { name: "Add a business" });
  await expect(dialog).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("add-business-dialog.png") });
  await dialog.getByLabel("Business name").fill("Caltech");
  await dialog.getByLabel("GSTIN").fill("27AAPFU0939F1ZV");
  await dialog.getByRole("button", { name: "Add business" }).click();
  await expect(page).toHaveURL(/\/app\/business\/3\/settings\/business$/);
  await expect(page.getByRole("heading", { name: "Finish setting up your business" })).toBeVisible();
  expect(submitted).toEqual({ business: { name: "Caltech", gstin: "27AAPFU0939F1ZV" } });
});
async function chooseState(page: Page, trigger: string, label = "State", stateName = "Tamil Nadu") {
  await page.locator(trigger).click();
  await page.getByRole("combobox", { name: `Search ${label.toLowerCase()}` }).fill(stateName);
  await page.getByRole("option", { name: stateName, exact: true }).click();
}

test("invoice reuses customer bill-to and saves an inline ship-to address", async ({ page }) => {
  const primary: BusinessCustomerAddress = {
    id: 40,
    customer_id: 4,
    label: "Bengaluru Registered Office",
    address: "1 MG Road, Bengaluru",
    state_code: "29",
    gstin: "29AABCT3518Q1ZF",
    usage: "either",
    is_primary_billing: true,
    is_primary_shipping: true,
  };
  const alternateBilling: BusinessCustomerAddress = {
    id: 41,
    customer_id: 4,
    label: "Chennai GST Registration",
    address: "2 Mount Road, Chennai",
    state_code: "33",
    gstin: "33AABCT3518Q1ZG",
    usage: "billing",
    is_primary_billing: false,
    is_primary_shipping: false,
  };
  let customerAddresses = [primary, alternateBilling];
  let submittedInvoice: Record<string, unknown> | undefined;
  await setup(page);
  await page.unroute(/\/api\/business\/1\/bootstrap$/);
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, customer_addresses: customerAddresses } }),
  );
  await page.route(/\/api\/business\/1\/customers\/4\/addresses$/, async (route) => {
    const body = route.request().postDataJSON().address;
    expect(body).toMatchObject({
      label: "Apollo Hospital, Mysore",
      address: "Apollo Main Road, Mysore",
      state_code: "29",
      usage: "shipping",
      is_primary_shipping: true,
    });
    const savedAddress: BusinessCustomerAddress = {
      ...body,
      id: 43,
      customer_id: 4,
      gstin: null,
      is_primary_billing: false,
    };
    customerAddresses = [...customerAddresses, savedAddress];
    await route.fulfill({ json: { address: savedAddress } });
  });
  await page.route(/\/api\/business\/1\/invoices$/, async (route) => {
    submittedInvoice = route.request().postDataJSON().invoice;
    await route.fulfill({
      json: {
        invoice: {
          ...invoice,
          billing_address_id: 41,
          shipping_address_id: 43,
        },
      },
    });
  });

  await page.goto("/app/business/1/invoices/new");
  await chooseCustomer(page, "Harbour Labs");
  await expect(page.getByRole("button", { name: "Select shipping address" })).toContainText(
    "Choose saved address",
  );
  await page.getByRole("button", { name: "Select billing address" }).click();
  await page.getByRole("combobox", { name: "Search billing addresses" }).fill("Chennai GST");
  await page.getByRole("option").filter({ hasText: "Chennai GST Registration" }).click();
  await expect(page.getByText("GSTIN 33AABCT3518Q1ZG")).toBeVisible();

  await page.getByRole("button", { name: "Select shipping address" }).click();
  await page.getByRole("option", { name: "Add saved address" }).click();
  await page.getByLabel("Label", { exact: true }).fill("Apollo Hospital, Mysore");
  await page.getByLabel("Address", { exact: true }).fill("Apollo Main Road, Mysore");
  await chooseState(page, "#customer-address-state", "State", "Karnataka");
  await chooseSelect(page.getByLabel("Use this address for"), "shipping");
  await page.getByText("Default shipping address").click();
  await page.getByRole("button", { name: "Save address" }).click();
  const invoiceParties = page.getByRole("region", { name: "Invoice parties" });
  await expect(invoiceParties.getByText("Apollo Main Road, Mysore")).toBeVisible();

  await chooseState(page, "#invoice-pos", "Place of supply", "Karnataka");
  await page.locator("#line-0-description").fill("Consulting");
  await page.locator("#line-0-sac").fill("998313");
  await page.locator("#line-0-price").fill("1000");
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect.poll(() => submittedInvoice).toMatchObject({
    customer_id: 4,
    billing_address_id: 41,
    shipping_address_id: 43,
  });
});

test("business dates allow typing, normalizing, Tab navigation and calendar selection", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/business/1/invoices/new");
  await page.locator("#invoice-date").fill("24/9/26");
  await page.locator("#invoice-date").press("Tab");
  await expect(page.locator("#invoice-date")).toHaveValue("24/09/2026");
  await expect(page.locator("#invoice-due")).toBeFocused();

  await page.locator("#invoice-due").fill("23/09/2026");
  await expect
    .poll(() =>
      page.locator("#invoice-due").evaluate((field: HTMLInputElement) => field.validity.valid),
    )
    .toBe(false);
  await page.locator("#invoice-due").fill("");
  await page.locator("#invoice-due").fill("26/09/2026");
  await page.locator("#invoice-due").press("Tab");
  await page.locator("#invoice-date").fill("27/09/2026");
  await page.locator("#invoice-date").press("Tab");
  await expect
    .poll(() =>
      page.locator("#invoice-due").evaluate((field: HTMLInputElement) => field.validity.valid),
    )
    .toBe(false);
  await page.locator("#invoice-date").fill("24/09/2026");
  await page.locator("#invoice-date").press("Tab");
  await page.locator("#invoice-due").fill("");

  await page.getByRole("button", { name: "Choose due date" }).click();
  const dueCalendar = page.locator('[data-slot="calendar"]:visible');
  await expect(dueCalendar.locator("button[data-day]").filter({ hasText: /^23$/ })).toBeDisabled();
  await expect(dueCalendar.locator("button[data-day]").filter({ hasText: /^24$/ })).toBeEnabled();
  await page.keyboard.press("Escape");
  await expect(dueCalendar).toHaveCount(0);

  await page.getByRole("button", { name: "Choose invoice date" }).click();
  const invoiceCalendar = page.locator('[data-slot="calendar"]:visible');
  await expect(invoiceCalendar).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("business-calendar.png") });
  await invoiceCalendar.locator("button[data-day]").filter({ hasText: /^25$/ }).click();
  await expect(page.locator("#invoice-date")).toHaveValue("25/09/2026");
  await expect(invoiceCalendar).toHaveCount(0);

  await page.locator("#invoice-date").focus();
  await page.locator("#invoice-date").press("Alt+ArrowDown");
  await expect(invoiceCalendar).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(invoiceCalendar).toHaveCount(0);
});

test("required place of supply stays required with searchable state picker", async ({ page }) => {
  await setup(page);
  let writes = 0;
  await page.route(/\/api\/business\/1\/invoices$/, (route) => {
    writes++;
    return route.fulfill({ json: { invoice } });
  });
  await page.goto("/app/business/1/invoices/new");
  await chooseCustomer(page, "Harbour Labs");
  await page.locator("#line-0-description").fill("Consulting");
  await page.locator("#line-0-sac").fill("998313");
  await page.locator("#line-0-price").fill("1000");
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  expect(writes).toBe(0);
  await expect(page.locator("#invoice-pos")).toBeFocused();
  await chooseState(page, "#invoice-pos", "Place of supply");
  await expect(page.locator("#invoice-pos")).toContainText("Tamil Nadu");
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect.poll(() => writes).toBe(1);
});

test("draft save and direct issue both work; PDF failures stay visible", async ({ page }, testInfo) => {
  await setup(page);
  let saved = { ...invoice };
  let issues = 0;
  await page.route(/\/api\/business\/1\/invoices$/, async (route) => {
    expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
    expect(String(route.request().postDataJSON().invoice.customer_id)).toBe("4");
    await route.fulfill({ json: { invoice: saved } });
  });
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice: saved } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/finalize$/, (route) => {
    issues++;
    expect(route.request().postDataJSON().id).toBe(9);
    saved = { ...saved, status: "issued", number: "INV/26-27/0001" };
    return route.fulfill({ json: { invoice: saved } });
  });
  await page.route(/\/api\/business\/1\/invoices\/9\/pdf$/, (route) =>
    route.fulfill({ status: 503, json: { error: "PDF temporarily unavailable." } }),
  );
  await page.goto("/app/business/1/invoices/new");
  await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeEnabled();
  await chooseCustomer(page, "Harbour Labs");
  await chooseState(page, "#invoice-pos", "Place of supply");
  await page.locator("#line-0-description").fill("Consulting");
  await page.locator("#line-0-sac").fill("998313");
  await page.locator("#line-0-price").fill("1000");
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(page).toHaveURL(/\/business\/1\/invoices\/9$/);
  await expect(page.getByText("₹1,180.00", { exact: true })).toBeVisible();
  expect(issues).toBe(0);
  await page.screenshot({
    path: testInfo.outputPath("business-invoice-desktop.png"),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({
    path: testInfo.outputPath("business-invoice-narrow.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Issue invoice", exact: true }).click();
  await expect(page.getByText("INV/26-27/0001", { exact: true }).first()).toBeVisible();
  expect(issues).toBe(1);
  await expect(page.locator("#line-0-description")).toBeDisabled();
  await page.getByRole("button", { name: "Download PDF", exact: true }).click();
  await expect(page.getByRole("alert").first()).toContainText("PDF temporarily unavailable.");
});

for (const document of [
  { kind: "invoice", path: "invoices", listName: "Invoices" },
  { kind: "quotation", path: "quotations", listName: "Quotations" },
] as const) {
  test(`unfinished new ${document.kind} survives reload and warns before navigation`, async ({ page }) => {
    await setup(page);
    await page.goto(`/app/business/1/${document.path}/new`);
    await page.locator("#line-0-description").fill("Recovered compressor service");
    await expect(page.getByText("Unsaved changes", { exact: true })).toBeVisible();

    const recoveryKey = `nila:business-document-draft:1:${document.kind}`;
    await expect
      .poll(() =>
        page.evaluate((key) => window.localStorage.getItem(key), recoveryKey),
      )
      .toContain("Recovered compressor service");

    page.once("dialog", (dialog) => dialog.accept());
    await page.reload();
    await expect(page.getByText("Recovered your unsaved work.")).toBeVisible();
    await expect(page.locator("#line-0-description")).toHaveValue(
      "Recovered compressor service",
    );

    page.once("dialog", (dialog) => dialog.dismiss());
    await page
      .getByRole("main")
      .getByRole("link", { name: document.listName, exact: true })
      .click();
    await expect(page).toHaveURL(new RegExp(`/${document.path}/new$`));
    await expect(page.locator("#line-0-description")).toHaveValue(
      "Recovered compressor service",
    );

    page.once("dialog", (dialog) => dialog.accept());
    await page
      .getByRole("main")
      .getByRole("link", { name: document.listName, exact: true })
      .click();
    await expect(page).toHaveURL(new RegExp(`/${document.path}$`));
    await expect.poll(() => page.evaluate((key) => localStorage.getItem(key), recoveryKey)).toBeNull();

    await page.goto(`/app/business/1/${document.path}/new`);
    await expect(page.locator("#line-0-description")).toHaveValue("");
  });
}

test("recovery keeps an explicitly cleared default ship-to address cleared", async ({ page }) => {
  await setup(page);
  const addresses: BusinessCustomerAddress[] = [
    {
      id: 40,
      customer_id: 4,
      label: "Registered office",
      address: "1 Mount Road, Chennai",
      state_code: "33",
      gstin: null,
      usage: "billing",
      is_primary_billing: true,
      is_primary_shipping: false,
    },
    {
      id: 43,
      customer_id: 4,
      label: "Default hospital",
      address: "Apollo Hospital, Bengaluru",
      state_code: "29",
      gstin: null,
      usage: "shipping",
      is_primary_billing: false,
      is_primary_shipping: true,
    },
  ];
  await page.unroute(/\/api\/business\/1\/bootstrap$/);
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, customer_addresses: addresses } }),
  );

  await page.goto("/app/business/1/invoices/new");
  await chooseCustomer(page, "Harbour Labs");
  const shipping = page.getByRole("button", { name: "Select shipping address" });
  await expect(shipping).toContainText("Default hospital");
  await shipping.click();
  await page.getByRole("option", { name: "Enter address manually" }).click();
  await expect(page.locator("#invoice-delivery")).toHaveValue("");
  await expect
    .poll(() =>
      page.evaluate(() =>
        localStorage.getItem("nila:business-document-draft:1:invoice"),
      ),
    )
    .toContain('"shippingTouched":true');

  page.once("dialog", (dialog) => dialog.accept());
  await page.reload();
  await expect(page.getByText("Recovered your unsaved work.")).toBeVisible();
  await expect(shipping).toContainText("Choose saved address");
  await expect(page.getByText("Apollo Hospital, Bengaluru")).toHaveCount(0);
});

test("new invoice issues in one action without creating a separate draft", async ({ page }) => {
  await setup(page);
  let draftWrites = 0;
  await page.route(/\/api\/business\/1\/invoices$/, (route) => {
    draftWrites++;
    return route.fulfill({ status: 500, json: { error: "Unexpected draft write" } });
  });
  await page.route(/\/api\/business\/1\/invoices\/finalize$/, (route) => {
    const body = route.request().postDataJSON();
    expect(body.id).toBeUndefined();
    expect(body.invoice.lines[0].description).toBe("Consulting");
    return route.fulfill({ json: { invoice: { ...invoice, status: "issued", number: "129/2026-27" } } });
  });
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice: { ...invoice, status: "issued", number: "129/2026-27" } } }),
  );
  await page.goto("/app/business/1/invoices/new");
  await chooseCustomer(page, "Harbour Labs");
  await chooseState(page, "#invoice-pos", "Place of supply");
  await page.locator("#line-0-description").fill("Consulting");
  await page.locator("#line-0-sac").fill("998312");
  await page.locator("#line-0-price").fill("1000");
  await page.getByRole("button", { name: "Issue invoice", exact: true }).click();
  await expect(page).toHaveURL(/\/business\/1\/invoices\/9$/);
  await expect(page.getByRole("button", { name: "Download PDF" })).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(() => localStorage.getItem("nila:business-document-draft:1:invoice")),
    )
    .toBeNull();
  expect(draftWrites).toBe(0);
});

test("saved draft warns only until its latest changes are saved", async ({ page }) => {
  await setup(page);
  let current = { ...invoice };
  await page.route(/\/api\/business\/1\/invoices\/9$/, async (route) => {
    if (route.request().method() === "PATCH") {
      current = { ...current, ...route.request().postDataJSON().invoice };
      return route.fulfill({ json: { invoice: current } });
    }
    return route.fulfill({ json: { invoice: current } });
  });
  await page.goto("/app/business/1/invoices/9");
  await page.locator("#line-0-description").fill("Latest saved wording");

  page.once("dialog", (dialog) => dialog.dismiss());
  await page.getByRole("main").getByRole("link", { name: "Invoices", exact: true }).click();
  await expect(page).toHaveURL(/\/invoices\/9$/);

  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Draft saved.");
  await page.getByRole("main").getByRole("link", { name: "Invoices", exact: true }).click();
  await expect(page).toHaveURL(/\/invoices$/);
});

test("issued invoice can be cancelled with a reason while keeping its PDF", async ({ page }) => {
  await setup(page);
  let current: BusinessInvoice = {
    ...invoice,
    status: "issued" as const,
    number: "INV/26-27/0001",
  };
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice: current } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/9\/cancel$/, (route) => {
    expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
    expect(route.request().postDataJSON()).toEqual({
      cancellation: { reason: "Duplicate invoice raised by mistake" },
    });
    current = {
      ...current,
      status: "cancelled" as const,
      cancelled_at: "2026-09-28T10:30:00Z",
      cancelled_by_id: 7,
      cancellation_reason: "Duplicate invoice raised by mistake",
    };
    return route.fulfill({ json: { invoice: current } });
  });

  await page.goto("/app/business/1/invoices/9");
  await expect(page.getByRole("button", { name: "Copy to new draft" })).toBeVisible();
  await page.getByRole("button", { name: "Cancel invoice", exact: true }).click();
  const dialog = page.getByRole("alertdialog");
  await expect(dialog.getByRole("button", { name: "Keep invoice" })).toBeFocused();
  const reason = dialog.getByLabel("Reason for cancellation");
  await expect(reason).toHaveAttribute("maxlength", "500");
  await expect(dialog.getByRole("button", { name: "Cancel invoice" })).toBeDisabled();
  await reason.fill("Duplicate invoice raised by mistake");
  await dialog.getByRole("button", { name: "Cancel invoice" }).click();

  await expect(dialog).toHaveCount(0);
  await expect(page).toHaveURL(/\/invoices\/9$/);
  const cancellation = page.getByRole("region", { name: "Cancellation details" });
  await expect(cancellation.getByText("Cancelled", { exact: true })).toBeVisible();
  await expect(cancellation).toContainText("Duplicate invoice raised by mistake");
  await expect(cancellation).toContainText("IST");
  await expect(page.getByRole("button", { name: "Download PDF" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Create credit note" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Cancel invoice" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Copy to new draft" })).toBeVisible();
});

test("failed invoice cancellation keeps the reason and explains the failure", async ({ page }) => {
  await setup(page);
  const issued = { ...invoice, status: "issued" as const, number: "INV/26-27/0001" };
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice: issued } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/9\/cancel$/, (route) =>
    route.fulfill({ status: 409, json: { error: "This GST period is closed." } }),
  );
  await page.goto("/app/business/1/invoices/9");
  await page.getByRole("button", { name: "Cancel invoice", exact: true }).click();
  const dialog = page.getByRole("alertdialog");
  await dialog.getByLabel("Reason for cancellation").fill("Wrong purchase order");
  await dialog.getByRole("button", { name: "Cancel invoice" }).click();
  await expect(dialog.getByRole("alert")).toContainText("This GST period is closed.");
  await expect(dialog.getByLabel("Reason for cancellation")).toHaveValue(
    "Wrong purchase order",
  );
  await expect(page).toHaveURL(/\/invoices\/9$/);
});

test("server validation retains draft without false issued state", async ({ page }) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/finalize$/, (route) =>
    route.fulfill({ status: 422, json: { error: "Complete business details before issuing." } }),
  );
  await page.goto("/app/business/1/invoices/9");
  await page.getByRole("button", { name: "Issue invoice", exact: true }).click();
  await expect(page.getByRole("alert").first()).toContainText("Complete business details");
  await expect(page.getByRole("button", { name: "Download PDF" })).toHaveCount(0);
  await expect(page.locator("#line-0-description")).toHaveValue("Consulting");
});
test("forbidden workspace exposes no customer or invoice controls", async ({ page }) => {
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ status: 403, json: { error: "You do not have access to this business." } }),
  );
  await page.goto("/app/business/1/invoices");
  await expect(page.getByRole("alert")).toContainText("do not have access");
  await expect(page.getByRole("link", { name: "New invoice" })).toHaveCount(0);
});
test("unsaved changes are included when issuing", async ({ page }) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice } }),
  );
  await page.goto("/app/business/1/invoices/9");
  await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeEnabled();
  await page.locator("#line-0-description").fill("Revised services");
  await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeEnabled();
  await page.route(/\/api\/business\/1\/invoices\/finalize$/, (route) => {
    expect(route.request().postDataJSON().invoice.lines[0].description).toBe("Revised services");
    return route.fulfill({ json: { invoice: { ...invoice, status: "issued", number: "INV/2627/0001" } } });
  });
  await page.getByRole("button", { name: "Issue invoice", exact: true }).click();
  await expect(page.getByRole("button", { name: "Download PDF" })).toBeVisible();
});
test("customer saves scoped and business profile confirms save", async ({ page }) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/customers$/, async (route) => {
    const body = route.request().postDataJSON();
    expect(body.customer.name).toBe("New customer");
    expect(body.customer.client_id).toBeUndefined();
    expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
    await route.fulfill({ json: { customer: { id: 5, ...body.customer } } });
  });
  await page.goto("/app/business/1/customers");
  await page.getByRole("button", { name: "Add customer", exact: true }).click();
  await page.getByLabel("Customer name").fill("New customer");
  await page.locator("#business-customer-form").getByLabel("Billing address").fill("Chennai");
  await chooseState(page, "#customer-state");
  await page.getByRole("button", { name: "Save customer" }).click();
  await expect(page.locator("#business-customer-form")).toHaveCount(0);
  await page.route(/\/api\/business\/1\/profile$/, (route) => {
    expect(route.request().postDataJSON().profile.address).toBe("New address");
    return route.fulfill({ json: { profile: bootstrap.profile } });
  });
  await page.getByRole("link", { name: "Settings", exact: true }).click();
  await page.getByLabel("Business address").fill("New address");
  await page.getByRole("button", { name: "Save business details" }).click();
  await expect(page.getByRole("status")).toHaveText("Settings saved.");
});

test("customer add stays in a dialog and records open on their own page", async ({ page }) => {
  await setup(page);
  let customerAddresses = [
    { id: 40, customer_id: 4, label: "Head office", address: "1 Mount Road, Chennai", state_code: "33", gstin: null, usage: "either", is_primary_billing: true, is_primary_shipping: true },
    ...Array.from({ length: 102 }, (_, index) => ({
      id: index + 41, customer_id: 4,
      label: `Hospital ${String(index + 1).padStart(3, "0")}`,
      address: `${index + 1} Main Street, Chennai`,
      state_code: "33", gstin: null, usage: "shipping",
      is_primary_billing: false, is_primary_shipping: false,
    })),
  ];
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) => route.fulfill({ json: {
    ...bootstrap,
    customer_addresses: customerAddresses,
  } }));
  await page.route(/\/api\/business\/1\/customers\/4\/addresses$/, (route) => {
    const input = route.request().postDataJSON().address;
    if (input.usage === "billing") {
      expect(input).toMatchObject({ label: "Accounts office", is_primary_billing: true });
      customerAddresses = customerAddresses.map((entry) => ({ ...entry, is_primary_billing: false }));
    } else {
      expect(input).toMatchObject({ label: "New hospital", usage: "shipping", is_primary_shipping: false });
    }
    const address = { ...input, id: input.usage === "billing" ? 201 : 200, customer_id: 4 };
    customerAddresses = [...customerAddresses, address];
    return route.fulfill({ json: { address } });
  });
  await page.route(/\/api\/business\/1\/customers\/4\/addresses\/122$/, (route) => {
    const input = route.request().postDataJSON().address;
    const address = { ...customerAddresses.find((entry) => entry.id === 122)!, ...input };
    customerAddresses = customerAddresses.map((entry) => entry.id === 122 ? address : entry);
    return route.fulfill({ json: { address } });
  });
  await page.goto("/app/business/1/customers");
  await page.getByRole("button", { name: "Add customer" }).click();
  await expect(page.getByRole("dialog", { name: "Add customer" })).toBeVisible();
  await expect(page.locator("#business-customer-form")).toBeVisible();
  await page.screenshot({ path: "../outputs/customer-design/customer-pass-1.png", fullPage: true });
  await page.getByRole("button", { name: "Cancel" }).click();
  await page.getByRole("link", { name: "Harbour Labs" }).click();
  await expect(page).toHaveURL(/\/app\/business\/1\/customers\/4$/);
  await expect(page.getByRole("heading", { name: "Service locations" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Hospital 001", exact: true })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Hospital 026", exact: true })).toHaveCount(0);
  await page.screenshot({ path: "../outputs/customer-design/customer-pass-2.png", fullPage: true });
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByRole("cell", { name: "Hospital 026", exact: true })).toBeVisible();
  await page.getByRole("textbox", { name: "Search service locations" }).fill("Hospital 082");
  await expect(page.getByRole("cell", { name: "Hospital 082", exact: true })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Hospital 026", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Edit Hospital 082" }).click();
  const editDialog = page.getByRole("dialog", { name: "Edit service location" });
  await editDialog.getByLabel("Hospital or location name").fill("Renamed hospital");
  await editDialog.getByRole("button", { name: "Save changes" }).click();
  await expect(editDialog).toHaveCount(0);
  await page.getByRole("textbox", { name: "Search service locations" }).fill("Renamed hospital");
  await expect(page.getByRole("cell", { name: "Renamed hospital", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Add location" }).click();
  const locationDialog = page.getByRole("dialog", { name: "Add service location" });
  await locationDialog.getByLabel("Hospital or location name").fill("New hospital");
  await locationDialog.getByLabel("Address", { exact: true }).fill("New Road, Chennai");
  await chooseState(page, "#saved-address-state");
  await locationDialog.getByRole("button", { name: "Save address" }).click();
  await expect(locationDialog).toHaveCount(0);
  await page.getByRole("textbox", { name: "Search service locations" }).fill("New hospital");
  await expect(page.getByRole("cell", { name: "New hospital", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Add billing address" }).click();
  const billingDialog = page.getByRole("dialog", { name: "Add billing address" });
  await billingDialog.getByLabel("Address label").fill("Accounts office");
  await billingDialog.getByLabel("Address", { exact: true }).fill("2 Mount Road, Chennai");
  await chooseState(page, "#saved-address-state");
  await billingDialog.getByRole("checkbox", { name: "Make this the default billing address" }).check();
  await billingDialog.getByRole("button", { name: "Save address" }).click();
  await expect(billingDialog).toHaveCount(0);
  await expect(page.getByText("Accounts office")).toBeVisible();
  await expect(page.getByText("Head office")).toBeVisible();
});

test("business details save contact info, numbering and a logo", async ({ page }, testInfo) => {
  await setup(page);
  const logoBytes = readFileSync(new URL("../../priv/static/images/og-image.png", import.meta.url));
  let state = bootstrap;
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) => route.fulfill({ json: state }));
  await page.route(/\/api\/business\/1\/profile$/, (route) => {
    const update = route.request().postDataJSON().profile;
    state = { ...state, profile: { ...state.profile!, ...update } };
    return route.fulfill({ json: { profile: state.profile } });
  });
  await page.route(/\/api\/business\/1\/quotation-numbering$/, (route) => {
    const update = route.request().postDataJSON().numbering;
    state = {
      ...state,
      quotation_numbering: { ...state.quotation_numbering, ...update },
    };
    return route.fulfill({ json: { quotation_numbering: state.quotation_numbering } });
  });
  await page.route(/\/api\/business\/1\/invoice-numbering$/, (route) => {
    const update = route.request().postDataJSON().numbering;
    state = {
      ...state,
      invoice_numbering: { ...state.invoice_numbering, ...update },
    };
    return route.fulfill({ json: { invoice_numbering: state.invoice_numbering } });
  });
  await page.route(/\/api\/business\/1\/profile\/assets\/logo(?:\?.*)?$/, (route) => {
    if (route.request().method() === "GET")
      return route.fulfill({ status: 200, contentType: "image/png", body: logoBytes });
    state = { ...state, profile: { ...state.profile!, has_logo: true } };
    return route.fulfill({ json: { profile: state.profile } });
  });
  await page.goto("/app/business/1/settings");
  await page.locator("#business-phone").fill("9962550448");
  await page.locator("#business-email").fill("quotes@example.com");
  await page.getByRole("button", { name: "Save business details" }).click();
  await expect(page.getByRole("status")).toContainText("saved");
  await page.screenshot({ path: testInfo.outputPath("business-profile-settings.png"), fullPage: true });
  await page.getByRole("link", { name: "Document numbers" }).click();
  await page.locator("#business-quote-next").fill("79/2026-27");
  await page.getByRole("button", { name: "Save quotation numbering" }).click();
  await expect(page.locator("#business-quote-next")).toHaveValue("79/2026-27");
  await chooseSelect(page.locator("#business-invoice-style"), "serial_fy");
  await page.locator("#business-invoice-next").fill("129");
  await page.getByRole("button", { name: "Save invoice numbering" }).click();
  await expect(page.locator("#business-invoice-next")).toHaveValue("129");
  await page.screenshot({ path: testInfo.outputPath("business-document-numbers.png"), fullPage: true });
  await page.getByRole("link", { name: "Branding" }).click();
  await page.locator("#business-logo").setInputFiles({
    name: "logo.png",
    mimeType: "image/png",
    buffer: logoBytes,
  });
  await expect(page.getByAltText("Current business logo")).toBeVisible();
  await expect
    .poll(() => page.getByAltText("Current business logo").evaluate((image: HTMLImageElement) => image.naturalWidth))
    .toBeGreaterThan(0);
  await page.screenshot({ path: testInfo.outputPath("business-branding-settings.png"), fullPage: true });
  expect(state.profile?.phone).toBe("9962550448");
  expect(state.profile?.email).toBe("quotes@example.com");
  expect(state.quotation_numbering.next_quotation_number).toBe("79/2026-27");
  expect(state.invoice_numbering.style).toBe("serial_fy");
  state = {
    ...state,
    quotation_numbering: { ...state.quotation_numbering, editable: false },
    invoice_numbering: { ...state.invoice_numbering, editable: false },
  };
  await page.goto("/app/business/1/settings/document-numbers");
  await expect(page.getByText("Next invoice: 129/2026-27")).toBeVisible();
  await expect(page.locator("#business-quote-next")).toHaveValue("79/2026-27");
  await expect(page.locator("#business-invoice-next")).toHaveCount(0);
  await expect(page.locator("#business-quote-next")).toBeVisible();
});
test("credit note carries original customer and services with explicit save and issue", async ({
  page,
}) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({
      json: {
        invoice: {
          ...invoice,
          status: "issued",
          number: "INV/26-27/0001",
          snapshot: {
            supplier: {
              name: "Breeze Services",
              address: "Chennai",
              gstin: bootstrap.business.gstin,
            },
            customer: bootstrap.customers[0],
          },
        },
      },
    }),
  );
  await page.goto("/app/business/1/invoices/9");
  await page.getByRole("link", { name: "Create credit note" }).click();
  await expect(page.getByRole("heading", { name: "Credit note", exact: true })).toBeVisible();
  await expect(page.getByRole("article", { name: "Editable invoice" })).toContainText(
    "Harbour Labs",
  );
  await expect(page.locator("#line-0-description")).toHaveValue("Consulting");
  await expect(page.getByRole("button", { name: "Issue credit note" })).toBeEnabled();
  await expect(page.getByText("INV/26-27/0001", { exact: true }).first()).toBeVisible();
});
test("saved edits survive reopen and issued party names use frozen snapshot", async ({ page }) => {
  await setup(page);
  let current = { ...invoice };
  await page.route(/\/api\/business\/1\/invoices\/9$/, async (route) => {
    if (route.request().method() === "PATCH")
      current = { ...current, ...route.request().postDataJSON().invoice };
    await route.fulfill({ json: { invoice: current } });
  });
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, invoices: [current] } }),
  );
  await page.goto("/app/business/1/invoices/9");
  await page.locator("#line-0-description").fill("Saved revision");
  await page.getByRole("button", { name: "Save draft" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Draft saved." })).toBeVisible();
  await page.getByRole("link", { name: "Invoices", exact: true }).first().click();
  await page
    .getByRole("row")
    .filter({ has: page.getByRole("link", { name: "Draft", exact: true }) })
    .getByRole("cell")
    .nth(1)
    .click();
  await expect(page.locator("#line-0-description")).toHaveValue("Saved revision");
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({
      json: {
        invoice: {
          ...current,
          status: "issued",
          number: "INV/26-27/0001",
          snapshot: {
            supplier: {
              name: "Original supplier",
              address: "Old supplier address",
              gstin: bootstrap.business.gstin,
            },
            customer: {
              name: "Original customer",
              address: "Old customer address",
              gstin: null,
              state_code: "33",
            },
          },
        },
      },
    }),
  );
  await page.reload();
  await expect(page.getByRole("region", { name: "Issued party details" })).toContainText(
    "Original customer",
  );
  await expect(page.getByRole("article", { name: "Editable invoice" })).toContainText(
    "Original supplier",
  );
});
test("focus and reconnect preserve unsaved edits", async ({ page }) => {
  await setup(page);
  let reads = 0;
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) => {
    reads++;
    return route.fulfill({ json: { invoice } });
  });
  await page.goto("/app/business/1/invoices/9");
  await page.locator("#line-0-description").fill("Unsaved local edit");
  const before = reads;
  await page.evaluate(() => {
    window.dispatchEvent(new Event("offline"));
    window.dispatchEvent(new Event("online"));
    window.dispatchEvent(new Event("focus"));
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await expect(page.locator("#line-0-description")).toHaveValue("Unsaved local edit");
  await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeEnabled();
  expect(reads).toBe(before);
});
test("empty document is editable immediately and totals come from Phoenix without saving or PDF", async ({
  page,
}, testInfo) => {
  await setup(page);
  let previews = 0,
    writes = 0,
    calculations = 0;
  await page.route(/\/api\/business\/1\/invoices\/preview$/, (route) => {
    previews++;
    return route.fulfill({ contentType: "application/pdf", body: previewPdf() });
  });
  await page.route(/\/api\/business\/1\/invoices$/, (route) => {
    writes++;
    return route.fulfill({ json: { invoice } });
  });
  await page.route(/\/api\/business\/1\/invoices\/calculate$/, (route) => {
    calculations++;
    expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
    return route.fulfill({
      json: {
        totals: { ...invoice.totals, total_paise: 1234567 },
        lines: [{ taxable_paise: 100000 }],
      },
    });
  });
  await page.goto("/app/business/1/invoices/new");
  await expect(page.getByRole("article", { name: "Editable invoice" })).toBeVisible();
  await expect(page.locator("#line-0-description")).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.locator("canvas")).toHaveCount(0);
  await chooseState(page, "#invoice-pos", "Place of supply");
  await page.locator("#line-0-price").fill("1000");
  await expect(page.getByText("₹12,345.67", { exact: true })).toBeVisible();
  expect(calculations).toBeGreaterThan(0);
  expect(previews).toBe(0);
  expect(writes).toBe(0);
  await page.screenshot({
    path: testInfo.outputPath("invoice-document-desktop.png"),
    fullPage: true,
  });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({
    path: testInfo.outputPath("invoice-document-narrow.png"),
    fullPage: true,
  });
});
test("new customer sheet keeps draft lines and selects saved customer", async ({ page }) => {
  await setup(page);
  const customers = [...bootstrap.customers];
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, customers } }),
  );
  let invoiceWrites = 0;
  await page.route(/\/api\/business\/1\/invoices$/, (route) => {
    invoiceWrites++;
    return route.fulfill({ json: { invoice } });
  });
  await page.route(/\/api\/business\/1\/customers$/, (route) => {
    const body = route.request().postDataJSON();
    expect(body.customer.client_id).toBeUndefined();
    const customer = { id: 5, ...body.customer };
    customers.push(customer);
    return route.fulfill({ json: { customer } });
  });
  await page.goto("/app/business/1/invoices/new");
  await page.locator("#line-0-description").fill("Keep these services");
  await page.locator("#line-0-price").fill("2300");
  await page.locator("#business-customer").click();
  await page.getByRole("combobox", { name: "Search customers" }).fill("New buyer");
  await page.getByRole("option", { name: /^Create/ }).click();
  await expect(page.locator("#invoice-customer-name")).toHaveValue("New buyer");
  await page.locator("#invoice-customer-address").fill("Chennai");
  await chooseState(page, "#invoice-customer-state");
  await page.locator("#business-save-customer").click();
  await expect(page.locator("#business-customer-sheet")).toHaveCount(0);
  await expect(page.locator("#business-customer")).toContainText("New buyer");
  await expect(page.locator("#line-0-description")).toHaveValue("Keep these services");
  await expect(page.locator("#line-0-price")).toHaveValue("2300");
  await expect(page).toHaveURL(/\/invoices\/new$/);
  expect(invoiceWrites).toBe(0);
});
test("PDF preview is explicit, uses unsaved input, reports errors and releases URL on close", async ({
  page,
}) => {
  await setup(page);
  let previews = 0;
  await page.addInitScript(() => {
    const active = new Set<string>();
    (window as unknown as { activePdfUrls: Set<string> }).activePdfUrls = active;
    const create = URL.createObjectURL.bind(URL),
      revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (object) => {
      const url = create(object);
      if (object instanceof Blob && object.type.includes("pdf")) active.add(url);
      return url;
    };
    URL.revokeObjectURL = (url) => {
      active.delete(url);
      revoke(url);
    };
  });
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/preview$/, (route) => {
    previews++;
    const input = route.request().postDataJSON().invoice;
    return input.notes === "Reject preview"
      ? route.fulfill({ status: 422, json: { error: "Check your service rate." } })
      : route.fulfill({
          contentType: "application/pdf",
          body: previewPdf(input.lines[0].description),
        });
  });
  await page.goto("/app/business/1/invoices/9");
  await page.locator("#line-0-description").fill("Unsaved PDF services");
  expect(previews).toBe(0);
  await page.getByRole("button", { name: "Preview PDF", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "PDF preview", exact: true });
  await expect(dialog.locator("[data-pdf-text]")).toContainText("Unsaved PDF services");
  await expect(dialog.locator("canvas")).toHaveAttribute("width", /[1-9][0-9]+/);
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect
    .poll(() =>
      page.evaluate(() => (window as unknown as { activePdfUrls: Set<string> }).activePdfUrls.size),
    )
    .toBe(0);
  await expect(page.locator("#line-0-description")).toHaveValue("Unsaved PDF services");
  await page.locator("#invoice-notes").fill("Reject preview");
  await page.getByRole("button", { name: "Preview PDF", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Check your service rate.");
  await expect(dialog.locator("canvas")).toHaveCount(0);
});
test("saved decimal GST rate shows its supported rate without a silent fallback", async ({
  page,
}) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({
      json: { invoice: { ...invoice, lines: [{ ...invoice.lines[0], gst_rate: "18.00" }] } },
    }),
  );
  await page.goto("/app/business/1/invoices/9");
  const gstRate = page.getByRole("combobox", { name: "GST % for item 1" });
  await expect(gstRate.locator('[data-slot="select-value"]')).toHaveText("18%");
  await gstRate.click();
  await expect(page.getByRole("option", { name: "18%" })).toHaveAttribute("aria-selected", "true");
  await page.getByRole("option", { name: "12%" }).click();
  await expect(gstRate.locator('[data-slot="select-value"]')).toHaveText("12%");
});
test("new and saved credit notes keep the original billed identity after customer edits", async ({
  page,
}) => {
  await setup(page);
  const original = {
    ...invoice,
    status: "issued",
    number: "INV/26-27/0001",
    snapshot: {
      supplier: { name: "Breeze Services", address: "Chennai", gstin: bootstrap.business.gstin },
      customer: {
        name: "Original billed customer",
        address: "Original billing address",
        gstin: null,
        state_code: "33",
      },
    },
  };
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice: original } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/10$/, (route) =>
    route.fulfill({
      json: {
        invoice: { ...invoice, id: 10, document_type: "credit_note", original_invoice_id: 9 },
      },
    }),
  );
  for (const path of ["/app/business/1/invoices/new?credit_for=9", "/app/business/1/invoices/10"]) {
    await page.goto(path);
    const document = page.getByRole("article", { name: "Editable invoice" });
    await expect(document).toContainText("Original billed customer");
    await expect(document).toContainText("Original billing address");
    await expect(document).not.toContainText("Harbour Labs");
  }
});
const quotation: BusinessInvoice = {
  ...invoice,
  id: 21,
  document_type: "quotation",
  valid_until: "2026-10-10",
  purchase_order_number: "WO-4821",
  purchase_order_date: "2026-09-15",
  delivery_address: "Project office",
  notes: "Payment within 15 days.",
};

for (const source of [
  {
    kind: "invoice",
    path: "invoices",
    value: { ...invoice, status: "issued" as const, number: "INV/26-27/0001" },
  },
  {
    kind: "quotation",
    path: "quotations",
    value: { ...quotation, status: "issued" as const, number: "QUO/26-27/0001" },
  },
] as const) {
  test(`copies a finalized ${source.kind} into a new draft with its fields retained`, async ({
    page,
  }) => {
    await setup(page);
    const copied = {
      ...source.value,
      id: source.value.id + 100,
      status: "draft" as const,
      number: null,
      invoice_date: "2026-09-28",
      due_date: "",
      cancelled_at: null,
      cancelled_by_id: null,
      cancellation_reason: null,
    };
    await page.route(
      new RegExp(`/api/business/1/invoices/${source.value.id}$`),
      (route) => route.fulfill({ json: { invoice: source.value } }),
    );
    await page.route(
      new RegExp(`/api/business/1/invoices/${source.value.id}/copy$`),
      (route) => {
        expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
        return route.fulfill({ json: { invoice: copied } });
      },
    );
    await page.route(new RegExp(`/api/business/1/invoices/${copied.id}$`), (route) =>
      route.fulfill({ json: { invoice: copied } }),
    );
    let dialogs = 0;
    page.on("dialog", async (dialog) => {
      dialogs++;
      await dialog.accept();
    });

    await page.goto(`/app/business/1/${source.path}/${source.value.id}`);
    await expect(page.getByRole("button", { name: "Copy to new draft" })).toBeVisible();
    if (source.kind === "quotation") {
      await expect(page.getByRole("button", { name: "Cancel invoice" })).toHaveCount(0);
    }
    await page.getByRole("button", { name: "Copy to new draft" }).click();
    await expect(page).toHaveURL(new RegExp(`/${source.path}/${copied.id}$`));
    await expect(page.locator("#line-0-description")).toHaveValue(
      source.value.lines[0].description,
    );
    await expect(page.getByRole("button", { name: "Save draft" })).toBeVisible();
    expect(dialogs).toBe(0);
  });
}

test("copy failure stays on the source and credit notes cannot be copied or cancelled", async ({
  page,
}) => {
  await setup(page);
  const issued = { ...invoice, status: "issued" as const, number: "INV/26-27/0001" };
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({ json: { invoice: issued } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/9\/copy$/, (route) =>
    route.fulfill({ status: 503, json: { error: "Could not copy this invoice." } }),
  );
  await page.goto("/app/business/1/invoices/9");
  await page.getByRole("button", { name: "Copy to new draft" }).click();
  await expect(page.getByRole("alert")).toContainText("Could not copy this invoice.");
  await expect(page).toHaveURL(/\/invoices\/9$/);

  const creditNote = {
    ...issued,
    id: 10,
    document_type: "credit_note" as const,
    original_invoice_id: null,
  };
  await page.route(/\/api\/business\/1\/invoices\/10$/, (route) =>
    route.fulfill({ json: { invoice: creditNote } }),
  );
  await page.goto("/app/business/1/invoices/10");
  await expect(page.getByRole("button", { name: "Copy to new draft" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Cancel invoice" })).toHaveCount(0);
});

test("quotation list separates quotations from issued invoices", async ({ page }) => {
  await setup(page);
  const readyQuote = { ...quotation, status: "issued" as const, number: "QUO/2627/0001" };
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({
      json: {
        ...bootstrap,
        invoices: [{ ...invoice, status: "issued", number: "INV/2627/0001" }, readyQuote],
      },
    }),
  );
  await page.goto("/app/business/1/quotations");
  await expect(page.getByRole("heading", { name: "Quotations", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "QUO/2627/0001", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "INV/2627/0001", exact: true })).toHaveCount(0);
  await page.getByRole("link", { name: "Invoices", exact: true }).first().click();
  await expect(page.getByRole("link", { name: "INV/2627/0001", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "QUO/2627/0001", exact: true })).toHaveCount(0);
});

test("invoice finder searches business fields and combines financial year and status", async ({
  page,
}) => {
  await setup(page);
  const documents: BusinessInvoice[] = [
    {
      ...invoice,
      id: 31,
      invoice_date: "2026-09-28",
      number: null,
      subject: "Annual chiller maintenance",
      delivery_address: "Guindy service depot",
    },
    {
      ...invoice,
      id: 32,
      invoice_date: "2026-03-14",
      number: "INV/25-26/0042",
      status: "issued",
      purchase_order_number: "PO-NORTH-77",
      snapshot: {
        customer: {
          name: "Caltech Refrigeration",
          address: "Chennai",
          gstin: null,
          state_code: "33",
        },
        shipping_name: "MS Ramaiah Hospital",
      },
    },
    {
      ...invoice,
      id: 33,
      invoice_date: "2026-05-05",
      number: "CN/26-27/0003",
      status: "cancelled",
      document_type: "credit_note",
      subject: "Refrigerant correction",
    },
  ];
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, invoices: documents } }),
  );

  await page.goto("/app/business/1/invoices");
  await expect(page.getByText("28 Sep 2026", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "CN/26-27/0003 · Credit note" })).toBeVisible();

  const search = page.getByRole("searchbox", { name: "Search invoices" });
  for (const [term, visible, hidden] of [
    ["inv/25", "INV/25-26/0042", "CN/26-27/0003"],
    ["calTECH", "INV/25-26/0042", "CN/26-27/0003"],
    ["chiller", "Draft", "INV/25-26/0042"],
    ["po-north", "INV/25-26/0042", "Draft"],
    ["ramaiah", "INV/25-26/0042", "Draft"],
    ["service depot", "Draft", "INV/25-26/0042"],
  ]) {
    await search.fill(term);
    await expect(page.getByRole("link", { name: visible, exact: visible === "Draft" })).toBeVisible();
    await expect(page.getByRole("link", { name: hidden, exact: hidden === "Draft" })).toHaveCount(0);
  }

  await search.fill("");
  await chooseSelect(page.getByLabel("Financial year"), "2026");
  await chooseSelect(page.getByLabel("Status"), "cancelled");
  await expect(page.getByRole("link", { name: "CN/26-27/0003 · Credit note" })).toBeVisible();
  await expect(page.getByRole("link", { name: "INV/25-26/0042" })).toHaveCount(0);

  await chooseSelect(page.getByLabel("Status"), "issued");
  await expect(page.getByText("No matching invoices")).toBeVisible();
  await search.fill("still missing");
  await page.getByRole("button", { name: "Clear filters" }).click();
  await expect(page.getByRole("link", { name: "INV/25-26/0042" })).toBeVisible();
  await expect(search).toHaveValue("");
  await expect(page.getByLabel("Financial year")).toHaveAttribute("data-value", "all");
  await expect(page.getByLabel("Status")).toHaveAttribute("data-value", "all");
});

test("quotation finder uses quotation statuses and keeps its true empty state distinct", async ({
  page,
}) => {
  await setup(page);
  const documents: BusinessInvoice[] = [
    { ...quotation, id: 41, number: null, invoice_date: "2026-04-01", status: "draft" },
    {
      ...quotation,
      id: 42,
      number: "QUO/25-26/0049",
      invoice_date: "2026-03-31",
      status: "issued",
      snapshot: {
        customer: { name: "Metro Hospital", address: "Mumbai", gstin: null, state_code: "27" },
      },
    },
    {
      ...quotation,
      id: 43,
      number: "QUO/26-27/0050",
      invoice_date: "2026-04-02",
      status: "accepted",
    },
    {
      ...quotation,
      id: 44,
      number: "QUO/26-27/0051",
      invoice_date: "2026-04-03",
      status: "issued",
      converted_invoice_id: 99,
    },
  ];
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, invoices: documents } }),
  );

  await page.goto("/app/business/1/quotations");
  await chooseSelect(page.getByLabel("Status"), "ready");
  await chooseSelect(page.getByLabel("Financial year"), "2025");
  await expect(page.getByRole("link", { name: "QUO/25-26/0049" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "Ready" })).toBeVisible();

  await page.getByRole("button", { name: "Clear filters" }).click();
  await page.getByRole("searchbox", { name: "Search quotations" }).fill("metro hospital");
  await expect(page.getByRole("link", { name: "QUO/25-26/0049" })).toBeVisible();
  await expect(page.getByRole("link", { name: "QUO/26-27/0050" })).toHaveCount(0);

  await page.getByRole("searchbox", { name: "Search quotations" }).fill("missing quote");
  await expect(page.getByText("No matching quotations")).toBeVisible();
  await expect(page.getByText("Your first quotation starts here")).toHaveCount(0);
});

test("empty document lists keep the create-first message and hide finder controls", async ({ page }) => {
  await setup(page);
  await page.goto("/app/business/1/invoices");
  await expect(page.getByText("Your first invoice starts here")).toBeVisible();
  await expect(page.getByRole("searchbox", { name: "Search invoices" })).toHaveCount(0);
});

test("goods quotation shows Bill to and Ship to together and saves HSN with unit", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/invoices\/calculate$/, (route) => {
    const line = route.request().postDataJSON().invoice.lines[0];
    const taxable = Math.round(Number(line.quantity) * Number(line.unit_price) * 100);
    const halfTax = Math.round((taxable * Number(line.gst_rate)) / 200);
    return route.fulfill({
      json: {
        totals: {
          taxable_paise: taxable,
          cgst_paise: halfTax,
          sgst_paise: halfTax,
          igst_paise: 0,
          total_paise: taxable + halfTax * 2,
        },
        lines: [
          { taxable_paise: taxable, cgst_paise: halfTax, sgst_paise: halfTax, igst_paise: 0 },
        ],
      },
    });
  });
  const saved = { ...quotation, id: 21 };
  let submitted: Record<string, unknown> = {};
  await page.route(/\/api\/business\/1\/invoices$/, (route) => {
    submitted = route.request().postDataJSON().invoice;
    return route.fulfill({ json: { invoice: { ...saved, ...submitted } } });
  });
  await page.route(/\/api\/business\/1\/invoices\/21$/, (route) =>
    route.fulfill({ json: { invoice: { ...saved, ...submitted } } }),
  );
  await page.goto("/app/business/1/quotations/new");
  await chooseCustomer(page, "Harbour Labs");
  const billTo = page.getByText("Bill to").locator("..");
  const shipTo = page.getByText("Ship to (optional)").locator("..");
  await expect(billTo).toContainText("Tamil Nadu · 33");
  await shipTo.getByRole("button", { name: "Add ship-to address" }).click();
  await page.locator("#invoice-delivery").fill("Parvathi Hospital, Chennai");
  await expect(shipTo).toContainText("Parvathi Hospital, Chennai");
  await chooseState(page, "#invoice-pos", "Place of supply");
  await chooseSelect(page.getByRole("combobox", { name: "Item type 1" }), "goods");
  await expect(page.locator("#line-0-unit")).toHaveAttribute("data-value", "");
  await page.locator("#line-0-description").fill("Refrigerant gas");
  await page.locator("#line-0-sac").fill("290339");
  await chooseSelect(page.locator("#line-0-unit"), "KGS");
  await page.locator("#line-0-price").fill("500");
  await expect(page.getByText("₹590.00", { exact: true })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("goods-quotation.png"), fullPage: true });
  await page.getByRole("button", { name: "Save draft", exact: true }).click();
  await expect(page).toHaveURL(/\/quotations\/21$/);
  expect((submitted.lines as Array<Record<string, unknown>>)[0]).toMatchObject({
    kind: "goods",
    description: "Refrigerant gas",
    sac: "290339",
    unit: "KGS",
  });
  expect(submitted.delivery_address).toBe("Parvathi Hospital, Chennai");
});

test("saved drafts can be deleted after confirmation", async ({ page }) => {
  await setup(page);
  let deleted = false;
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({
      json: { ...bootstrap, invoices: deleted ? [] : [quotation] },
    }),
  );
  await page.route(/\/api\/business\/1\/invoices\/21$/, (route) => {
    if (route.request().method() === "DELETE") {
      expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
      deleted = true;
      return route.fulfill({ json: { deleted: true } });
    }
    return route.fulfill({ json: { invoice: quotation } });
  });

  await page.goto("/app/business/1/quotations/21");
  const trigger = page.locator("#root").getByRole("button", { name: "Delete draft", exact: true });
  await trigger.click();
  const dialog = page.getByRole("alertdialog");
  await expect(dialog.getByRole("heading", { name: "Delete draft quotation?" })).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(trigger).toBeFocused();

  await trigger.click();
  await dialog.getByRole("button", { name: "Delete draft", exact: true }).click();
  await expect(page).toHaveURL(/\/quotations$/);
  expect(deleted).toBe(true);
});

test("quotation editor sets the next number without losing the draft", async ({ page }, testInfo) => {
  await setup(page);
  let state = bootstrap;
  let writes = 0;
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) => route.fulfill({ json: state }));
  await page.route(/\/api\/business\/1\/quotation-numbering$/, (route) => {
    const update = route.request().postDataJSON().numbering;
    state = { ...state, quotation_numbering: { ...state.quotation_numbering, ...update } };
    writes++;
    return route.fulfill({ json: { quotation_numbering: state.quotation_numbering } });
  });
  await page.goto("/app/business/1/quotations/new");
  await expect(page.getByRole("article", { name: "Editable invoice" })).toContainText("QT/2627/0001");
  await page.locator("#invoice-subject").fill("Descaling for F70");
  await page.getByRole("button", { name: "Edit" }).click();
  await expect(page).toHaveURL(/\/quotations\/new$/);
  await page.locator("#quotation-number-input").fill("GR-50");
  await expect(page.getByText("Next quotations: GR-51, GR-52, …")).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("quotation-numbering-dialog.png"), fullPage: true });
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByRole("article", { name: "Editable invoice" })).toContainText("GR-50");
  await expect(page.locator("#invoice-subject")).toHaveValue("Descaling for F70");
  await page.screenshot({ path: testInfo.outputPath("quotation-numbering-editor.png"), fullPage: true });
  expect(writes).toBe(1);
});

test("finalized quotation creates a linked editable revision", async ({ page }) => {
  await setup(page);
  const original = {
    ...quotation,
    status: "issued" as const,
    number: "79/2026-27",
    subject: "Compressor and Pipe Supply",
  };
  const revision = {
    ...original,
    id: 23,
    status: "draft" as const,
    number: null,
    revised_from_id: original.id,
  };
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, invoices: [original, revision] } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/21$/, (route) =>
    route.fulfill({ json: { invoice: original } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/23$/, (route) =>
    route.fulfill({ json: { invoice: revision } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/21\/revise$/, (route) =>
    route.fulfill({ json: { invoice: revision } }),
  );
  await page.goto("/app/business/1/quotations/21");
  await page.getByRole("button", { name: "Revise quotation" }).click();
  await expect(page).toHaveURL(/\/quotations\/23$/);
  await expect(page.locator("#invoice-subject")).toHaveValue("Compressor and Pipe Supply");
  await expect(page.getByRole("link", { name: "79/2026-27" })).toHaveAttribute(
    "href",
    "/app/business/1/quotations/21",
  );
  await expect(page.getByRole("button", { name: "Finalize quotation" })).toBeEnabled();
});

test("finalized quotation reads as a document without clipped item facts", async ({
  page,
}, testInfo) => {
  await setup(page);
  const finalized = {
    ...quotation,
    status: "issued" as const,
    number: "50/2026-27",
    valid_until: null,
    subject: "Supply of ACS coil",
    notes: "",
    place_of_supply: "29",
    lines: [
      {
        description: "MRI ACS COIL",
        kind: "goods" as const,
        sac: "84159000",
        quantity: "1",
        unit: "NOS",
        unit_price: "20500",
        gst_rate: "18",
      },
      {
        description: "Air Cargo and Transportation Charges",
        kind: "service" as const,
        sac: "996531",
        quantity: "1",
        unit: "service",
        unit_price: "6000",
        gst_rate: "18",
      },
    ],
    totals: {
      taxable_paise: 2_650_000,
      cgst_paise: 0,
      sgst_paise: 0,
      igst_paise: 477_000,
      total_paise: 3_127_000,
    },
    snapshot: {
      supplier: {
        name: "Caltech Refrigeration",
        address: "Padi, Chennai - 600050",
        gstin: "33BPBPK1081A1ZO",
        state_code: "33",
      },
      customer: {
        name: "Siemens Healthcare Pvt Ltd",
        address: "Bengaluru - 560001",
        gstin: "29AAVCS8021P1ZB",
        state_code: "29",
      },
      delivery_address: "MS Ramaiah Hospital\nBangalore",
      shipping_name: "MS Ramaiah Hospital",
      delivery_state_code: "29",
      total_in_words: "Rupees Thirty One Thousand Two Hundred Seventy and Zero paise only",
      lines: [
        {
          description: "MRI ACS COIL",
          kind: "goods" as const,
          sac: "84159000",
          quantity: "1",
          unit: "NOS",
          unit_price: "20500",
          gst_rate: "18",
          taxable_paise: 2_050_000,
          cgst_paise: 0,
          sgst_paise: 0,
          igst_paise: 369_000,
        },
        {
          description: "Air Cargo and Transportation Charges",
          kind: "service" as const,
          sac: "996531",
          quantity: "1",
          unit: "service",
          unit_price: "6000",
          gst_rate: "18",
          taxable_paise: 600_000,
          cgst_paise: 0,
          sgst_paise: 0,
          igst_paise: 108_000,
        },
      ],
    },
  };
  await page.route(/\/api\/business\/1\/invoices\/21$/, (route) =>
    route.fulfill({ json: { invoice: finalized } }),
  );

  await page.goto("/app/business/1/quotations/21");
  const document = page.getByRole("article", { name: "Finalized quotation" });
  await expect(page.getByRole("button", { name: "Delete draft", exact: true })).toHaveCount(0);
  await expect(document).toBeVisible();
  await expect(document.locator("input, textarea, [role=combobox]")).toHaveCount(0);
  await expect(document.getByText("22 Sep 2026", { exact: true })).toBeVisible();
  await expect(document.getByText("Valid until", { exact: true })).toHaveCount(0);
  await expect(document.getByText("Notes", { exact: true })).toHaveCount(0);
  await expect(
    document.getByText("Rupees Thirty One Thousand Two Hundred Seventy only"),
  ).toBeVisible();

  for (const fact of ["84159000", "1 NOS", "996531", "1 service"]) {
    const cell = document.getByText(fact, { exact: true });
    await expect(cell).toBeVisible();
    expect(await cell.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true);
  }
  await page.screenshot({
    path: testInfo.outputPath("finalized-quotation-document.png"),
    fullPage: true,
  });
});

test("quotation builder finalizes explicitly, accepts, and converts to one invoice draft with fields retained", async ({
  page,
}, testInfo) => {
  await setup(page);
  let current = { ...quotation };
  let savedInput: Record<string, unknown> = {};
  let conversions = 0;
  let finalizations = 0;
  const converted = {
    ...quotation,
    id: 22,
    document_type: "invoice" as const,
    valid_until: null,
    purchase_order_number: null,
    purchase_order_date: null,
    status: "draft" as const,
    number: null,
  };
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, invoices: [current] } }),
  );
  await page.route(/\/api\/business\/1\/quotations\/finalize$/, (route) => {
    finalizations++;
    savedInput = route.request().postDataJSON().invoice;
    expect(route.request().postDataJSON().id).toBeUndefined();
    expect(savedInput.document_type).toBe("quotation");
    expect(savedInput.valid_until).toBe("2026-10-10");
    current = { ...current, ...savedInput, status: "issued", number: "QUO/2627/0001" };
    return route.fulfill({ json: { invoice: current } });
  });
  await page.route(/\/api\/business\/1\/invoices\/21$/, (route) =>
    route.fulfill({ json: { invoice: current } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/22$/, (route) =>
    route.fulfill({
      json: {
        invoice: {
          ...converted,
          ...savedInput,
          document_type: "invoice",
          valid_until: null,
          purchase_order_number: "PO-77",
          purchase_order_date: "2026-09-25",
        },
      },
    }),
  );
  await page.route(/\/api\/business\/1\/invoices\/21\/quotation-status$/, (route) => {
    const body = route.request().postDataJSON();
    if (body.status === "awaiting_po") {
      expect(body.sent_on).toBe("2026-09-23");
      current = { ...current, status: "awaiting_po", sent_on: body.sent_on };
    } else {
      expect(body).toEqual({
        status: "accepted",
        purchase_order_number: "PO-77",
        purchase_order_date: "2026-09-25",
      });
      current = {
        ...current,
        status: "accepted",
        purchase_order_number: body.purchase_order_number,
        purchase_order_date: body.purchase_order_date,
      };
    }
    return route.fulfill({ json: { invoice: current } });
  });
  await page.route(/\/api\/business\/1\/invoices\/21\/convert$/, async (route) => {
    conversions++;
    expect(route.request().headers()["x-csrf-token"]).toBe("business-csrf");
    current = { ...current, status: "converted", converted_invoice_id: 22 };
    await route.fulfill({
      json: {
        invoice: {
          ...converted,
          ...savedInput,
          document_type: "invoice",
          valid_until: null,
          purchase_order_number: current.purchase_order_number,
          purchase_order_date: current.purchase_order_date,
        },
        quotation: current,
      },
    });
  });
  await page.goto("/app/business/1/quotations/new");
  await expect(page.getByRole("heading", { name: "Quotation", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Finalize quotation", exact: true }).click();
  expect(finalizations).toBe(0);
  await chooseCustomer(page, "Harbour Labs");
  await chooseState(page, "#invoice-pos", "Place of supply");
  await page.locator("#invoice-date").fill("22/09/2026");
  await page.locator("#quotation-valid-until").fill("10/10/2026");
  await page.locator("#line-0-description").fill("Quoted consulting");
  await page.locator("#line-0-sac").fill("998313");
  await page.locator("#line-0-price").fill("1000");
  await page.locator("#invoice-notes").fill("Payment within 15 days.");
  await page.locator("#invoice-subject").fill("Compressor and Pipe Supply and Insulation");
  await page.getByRole("button", { name: "Add ship-to address" }).click();
  await page.locator("#invoice-delivery").fill("IndiraGandhi Hospital, Puducherry");
  await expect(page.getByText("This ship-to has no state.", { exact: false })).toBeVisible();
  page.once("dialog", async (dialog) => {
    expect(dialog.message()).toBe("This ship-to site or address has no state. Finalize anyway?");
    await dialog.dismiss();
  });
  await page.getByRole("button", { name: "Finalize quotation", exact: true }).click();
  expect(finalizations).toBe(0);
  await chooseState(page, "#invoice-delivery-state", "Ship-to state", "Puducherry");
  await expect(page.getByRole("combobox", { name: "Search ship-to state" })).toBeHidden();
  await expect(page.getByText(/Billing and delivery states differ/)).toBeVisible();
  await page.getByRole("button", { name: "Add customer reference" }).click();
  await page.locator("#invoice-reference").fill("WO-4821");
  await expect(page.locator("#invoice-reference-date")).toHaveCount(0);
  const editor = page.getByRole("article", { name: "Editable invoice" });
  await expect(editor.locator("span").filter({ hasText: /^Type$/ })).toBeVisible();
  await expect(editor.getByText("Item / description", { exact: true })).toBeVisible();
  expect((await page.locator("#line-0-description").boundingBox())?.y).toBeLessThan(1000);
  await page.keyboard.press("Escape");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({
    path: testInfo.outputPath("quotation-editor.png"),
    fullPage: true,
  });
  await page.getByRole("button", { name: "Finalize quotation", exact: true }).click();
  await expect(page).toHaveURL(/\/quotations\/21$/);
  expect(finalizations).toBe(1);
  expect(savedInput.subject).toBe("Compressor and Pipe Supply and Insulation");
  expect(savedInput.delivery_state_code).toBe("34");
  await expect(page.getByRole("button", { name: "Download PDF", exact: true })).toBeVisible();
  await expect(page.getByRole("article", { name: "Finalized quotation" })).toBeVisible();
  await expect(page.locator("#line-0-description")).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Create credit note" })).toHaveCount(0);
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download PDF", exact: true }).click();
  expect((await download).suggestedFilename()).toMatch(/\.pdf$/);
  await page.getByRole("button", { name: "Mark sent", exact: true }).click();
  await page.locator("#quotation-sent-on").fill("2026-09-23");
  await page.getByRole("dialog").getByRole("button", { name: "Mark sent", exact: true }).click();
  await expect(
    page
      .getByText("Quotations are not included in sales or GST workings.", { exact: true })
      .locator(".."),
  ).toContainText("Awaiting PO");
  await page.getByRole("button", { name: "Mark accepted", exact: true }).click();
  await page.locator("#quotation-po-number").fill("PO-77");
  await page.locator("#quotation-po-date").fill("2026-09-25");
  await page.getByRole("dialog").getByRole("button", { name: "Mark accepted", exact: true }).click();
  await expect(page.getByRole("button", { name: "Convert to invoice", exact: true })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("quotation-accepted.png"), fullPage: true });
  await page.getByRole("button", { name: "Convert to invoice", exact: true }).click();
  await expect(page).toHaveURL(/\/invoices\/22$/);
  expect(conversions).toBe(1);
  await expect(page.getByRole("heading", { name: "Tax invoice", exact: true })).toBeVisible();
  await expect(page.locator("#line-0-description")).toHaveValue("Quoted consulting");
  await expect(page.locator("#invoice-reference")).toHaveValue("PO-77");
  await expect(page.locator("#invoice-reference-date")).toBeVisible();
  await expect(page.locator("#invoice-notes")).toHaveValue("Payment within 15 days.");
  await expect(page.locator("#invoice-subject")).toHaveValue(
    "Compressor and Pipe Supply and Insulation",
  );
  await expect(page.getByRole("button", { name: "Issue invoice", exact: true })).toBeVisible();
});

test("quotation transition errors stay visible and conversion does not claim success", async ({
  page,
}) => {
  await setup(page);
  const accepted = { ...quotation, status: "accepted", number: "QUO/2627/0001" };
  await page.route(/\/api\/business\/1\/invoices\/21$/, (route) =>
    route.fulfill({ json: { invoice: accepted } }),
  );
  await page.route(/\/api\/business\/1\/invoices\/21\/convert$/, (route) =>
    route.fulfill({ status: 409, json: { error: "Quotation changed. Reload before converting." } }),
  );
  await page.goto("/app/business/1/quotations/21");
  await page.getByRole("button", { name: "Convert to invoice", exact: true }).click();
  await expect(page.getByRole("alert").first()).toContainText("Quotation changed");
  await expect(page).toHaveURL(/\/quotations\/21$/);
});

const savedService = {
  id: 31,
  description: "Monthly consulting",
  sac: "998313",
  unit: "hour",
  unit_price: "2500.50",
  gst_rate: "18.00",
};
async function mockServices(page: Page) {
  let services = [{ ...savedService }];
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({ json: { ...bootstrap, services } }),
  );
  await page.route(/\/api\/business\/1\/services(?:\/\d+)?$/, async (route) => {
    const request = route.request();
    const id = Number(new URL(request.url()).pathname.split("/").at(-1));
    if (request.method() === "GET") return route.fulfill({ json: { services } });
    expect(request.headers()["x-csrf-token"]).toBe("business-csrf");
    if (request.method() === "DELETE") {
      services = services.filter((service) => service.id !== id);
      return route.fulfill({ json: { ok: true } });
    }
    const attrs = request.postDataJSON().service;
    expect(attrs.client_id).toBeUndefined();
    const service = { ...attrs, id: request.method() === "PATCH" ? id : 32 };
    services =
      request.method() === "PATCH"
        ? services.map((current) => (current.id === id ? service : current))
        : [...services, service];
    return route.fulfill({ json: { service } });
  });
}

test("saved services catalogue creates, edits and removes reusable defaults", async ({
  page,
}, testInfo) => {
  await setup(page);
  await mockServices(page);
  await page.goto("/app/business/1/services");
  await expect(page.getByRole("heading", { name: "Items", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Add item", exact: true }).click();
  let dialog = page.getByRole("dialog");
  await dialog.getByLabel("Description", { exact: true }).fill("Annual support");
  await dialog.getByLabel("HSN/SAC", { exact: true }).fill("998313");
  await dialog.getByLabel("Unit", { exact: false }).fill("year");
  await dialog.getByLabel("Rate", { exact: false }).fill("12000");
  await chooseSelect(dialog.getByLabel("GST", { exact: false }), "18");
  await dialog.getByRole("button", { name: "Save item", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("Annual support", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Edit Annual support", exact: true }).click();
  dialog = page.getByRole("dialog");
  await dialog.getByLabel("Rate", { exact: false }).fill("14000");
  await dialog.getByRole("button", { name: "Save item", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("₹14,000.00", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Delete Annual support", exact: true }).click();
  const confirmation = page.getByRole("alertdialog");
  await expect(confirmation.getByRole("button", { name: "Cancel" })).toBeFocused();
  await page.mouse.click(10, 10);
  await expect(confirmation).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("remove-service.png") });
  await confirmation.getByRole("button", { name: "Cancel" }).click();
  await expect(
    page.getByRole("button", { name: "Delete Annual support", exact: true }),
  ).toBeFocused();
  await page.getByRole("button", { name: "Delete Annual support", exact: true }).click();
  await page.getByRole("button", { name: "Remove item", exact: true }).click();
  await expect(page.getByText("Annual support", { exact: true })).toHaveCount(0);
  await expect(page.getByText("Monthly consulting", { exact: true })).toBeVisible();
});

for (const document of ["invoices", "quotations"])
  test(`saved services picker fills ${document} without changing quantity or preventing manual edits`, async ({
    page,
  }) => {
    await setup(page);
    await mockServices(page);
    let writes = 0;
    await page.route(/\/api\/business\/1\/services(?:\/\d+)?$/, (route) => {
      if (route.request().method() !== "GET") writes++;
      return route.fulfill({ json: { services: [savedService] } });
    });
    await page.goto(`/app/business/1/${document}/new`);
    await page.locator("#line-0-quantity").fill("3.5");
    await page.getByRole("button", { name: "Select saved item 1", exact: true }).click();
    await page.getByRole("combobox", { name: "Search items" }).fill("consulting");
    await page.getByRole("option", { name: /Monthly consulting/ }).click();
    await expect(page.locator("#line-0-description")).toHaveValue("Monthly consulting");
    await expect(page.locator("#line-0-sac")).toHaveValue("998313");
    await expect(page.locator("#line-0-price")).toHaveValue("2500.50");
    await expect(page.locator("#line-0-unit")).toHaveValue("hour");
    await expect(page.locator('#line-0-gst [data-slot="select-value"]')).toHaveText("18%");
    await expect(page.locator("#line-0-quantity")).toHaveValue("3.5");
    await page.locator("#line-0-description").fill("Client-specific consulting");
    await page.locator("#line-0-price").fill("2400");
    await expect(page.locator("#line-0-description")).toHaveValue("Client-specific consulting");
    expect(writes).toBe(0);
  });

test("saved invoice lines stay unchanged after catalogue edits", async ({ page }) => {
  await setup(page);
  await mockServices(page);
  await page.route(/\/api\/business\/1\/invoices\/9$/, (route) =>
    route.fulfill({
      json: { invoice: { ...invoice, lines: [{ ...savedService, quantity: "2" }] } },
    }),
  );
  await page.goto("/app/business/1/services");
  await page.getByRole("button", { name: "Edit Monthly consulting", exact: true }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Description", { exact: true }).fill("Repriced consulting");
  await dialog.getByLabel("Rate", { exact: false }).fill("9999");
  await dialog.getByRole("button", { name: "Save item", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.goto("/app/business/1/invoices/9");
  await expect(page.locator("#line-0-description")).toHaveValue("Monthly consulting");
  await expect(page.locator("#line-0-price")).toHaveValue("2500.50");
  await expect(page.locator("#line-0-quantity")).toHaveValue("2");
});

test("nullable profile facts become blank editable fields", async ({ page }, testInfo) => {
  await setup(page);
  await page.route(/\/api\/business\/1\/bootstrap$/, (route) =>
    route.fulfill({
      json: {
        ...bootstrap,
        profile: { ...bootstrap.profile, legal_name: null, address: null, state_code: null },
      },
    }),
  );
  let submitted: unknown;
  await page.route(/\/api\/business\/1\/profile$/, async (route) => {
    submitted = route.request().postDataJSON();
    await route.fulfill({ json: { profile: bootstrap.profile } });
  });
  await page.goto("/app/business/1/settings");
  await expect(page.locator("#business-name")).toHaveValue("Breeze Services");
  await expect(page.locator("#business-address")).toHaveValue("");
  await page.locator("#business-address").fill("Chennai");
  await page.getByRole("button", { name: "Save business details" }).click();
  await expect(page.getByRole("status")).toHaveText("Settings saved.");
  expect(submitted).toMatchObject({
    profile: { legal_name: "Breeze Services", address: "Chennai", state_code: "33" },
  });
  await page.screenshot({ path: testInfo.outputPath("business-settings.png") });
});
