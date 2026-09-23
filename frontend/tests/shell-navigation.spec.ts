import { mockNavigation } from "./fixtures/navigation";
import { expect, test, type Page } from "@playwright/test";

const clients = [
  { id: 2, name: "Harbour Services", gstin: "33AAAAA1234A1Z5" },
  { id: 3, name: "Orchard Trading", gstin: "29BBBBB1234B1Z5" },
];
const user = { name: "Accountant", org: "Test firm" };

test("Clients keeps the selected workspace and firm breadcrumb", async ({ page }, testInfo) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales");
  const sidebar = page.getByRole("complementary", { name: "Workspace navigation" });
  await sidebar.getByRole("link", { name: "Clients", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Clients", exact: true })).toBeVisible();
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeVisible();
  await expect(sidebar.getByRole("link", { name: "Sales & GSTR-1" })).toHaveAttribute(
    "href",
    "/app/gst/2/2026-06/sales",
  );
  await expect(sidebar.getByRole("link", { name: "Purchases & ITC" })).toHaveAttribute(
    "href",
    "/app/gst/2/2026-06/purchases",
  );
  await expect(sidebar.getByRole("link", { name: "Clients", exact: true })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.getByRole("navigation", { name: "Breadcrumb" })).toContainText("Test firm");
  await page.screenshot({ path: testInfo.outputPath("clients-context.png"), fullPage: true });
  await sidebar.getByRole("link", { name: "Sales & GSTR-1" }).click();
  await expect(page).toHaveURL("/app/gst/2/2026-06/sales");
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).click();
  await page.getByRole("link", { name: "View all clients" }).click();
  await expect(page).toHaveURL("/app/clients?period=2026-06");
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).click();
  await page.getByRole("option", { name: /Orchard Trading/ }).click();
  await expect(page).toHaveURL("/app/gst/3/2026-06/sales");
});

test("directory has no client navigation before selection or after access is removed", async ({
  page,
}) => {
  await setup(page);
  await page.goto("/app/clients");
  await expect(page.getByRole("heading", { name: "Clients", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Sales & GSTR-1" })).toHaveCount(0);
  await page.goto("/app/gst/2/2026-06/sales");
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, (route) =>
    route.fulfill({ json: { clients: [], user, can_edit: true, period: "2026-06" } }),
  );
  await page.getByRole("complementary").getByRole("link", { name: "Clients", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Clients", exact: true })).toBeVisible();
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Sales & GSTR-1" })).toHaveCount(0);
});
async function setup(page: Page) {
  await mockNavigation(page);
  await page.route("**/api/workspace/sales/*/*", (route) => {
    const parts = new URL(route.request().url()).pathname.split("/");
    const client = clients.find((item) => item.id === Number(parts[4]))!;
    const period = parts[5];
    const base = `/gst/${client.id}/${period}/sales`;
    return route.fulfill({
      json: {
        client,
        clients,
        user,
        period,
        month_label: period,
        can_upload: true,
        deadline: "2026-07-11",
        invoice_count: 0,
        review_count: 0,
        month_issue_count: 0,
        taxable: "₹0.00",
        tax: "₹0.00",
        uploads: { files: 0, unfinished: false },
        rows: [],
        sections: [],
        links: {
          upload: `${base}/upload`,
          uploads: `${base}/uploads`,
          working: base,
          purchases: `/gst/${client.id}/${period}/purchases`,
        },
      },
    });
  });
  await page.route(/\/api\/workspace\/clients(?:\?.*)?$/, (route) =>
    route.fulfill({ json: { clients, user, can_edit: true, period: "2026-06" } }),
  );
}

test("first client selection respects the directory's explicit month", async ({ page }) => {
  await setup(page);
  await page.goto("/app/clients?period=2026-04");
  await page.getByLabel("Select client", { exact: true }).click();
  await page.getByRole("option", { name: /Orchard Trading/ }).click();
  await expect(page).toHaveURL("/app/gst/3/2026-04/sales");
});

test("client switch searches GSTIN, preserves period and drops another client's search", async ({
  page,
}) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales/register?q=private&filter=ready");
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).click();
  await page.getByRole("combobox", { name: "Search clients" }).fill("29BBBBB");
  await expect(page.getByRole("option", { name: /Orchard Trading/ })).toBeVisible();
  await expect(page.getByRole("option", { name: /Harbour Services/ })).toHaveCount(0);
  await page.getByRole("combobox", { name: "Search clients" }).press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL("/app/gst/3/2026-06/sales/register?filter=ready");
});

test("collapsed sidebar retains client access and survives refresh", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales");
  await page.getByRole("button", { name: "Collapse sidebar" }).click();
  await page.reload();
  await expect(page.getByRole("button", { name: "Expand sidebar" })).toBeVisible();
  await page.getByLabel("Switch client: Harbour Services", { exact: true }).click();
  await expect(page.getByRole("combobox", { name: "Search clients" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeFocused();
});

test("sign out submits Phoenix method override and CSRF", async ({ page }) => {
  await setup(page);
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "csrf-proof";
      document.head.append(meta);
    }),
  );
  await page.goto("/app/gst/2/2026-06/sales");
  await page.route("**/users/log_out", (route) =>
    route.fulfill({ contentType: "text/html", body: "Signed out" }),
  );
  await page.getByRole("button", { name: "Open account menu" }).click();
  const request = page.waitForRequest("**/users/log_out");
  await page.getByRole("menuitem", { name: "Sign out" }).click();
  const sent = await request;
  expect(sent.method()).toBe("POST");
  expect(new URLSearchParams(sent.postData()!).get("_method")).toBe("delete");
  expect(new URLSearchParams(sent.postData()!).get("_csrf_token")).toBe("csrf-proof");
});

test("workspace survives directory reload, full page return and new tabs", async ({
  page,
}, info) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales");
  await page.getByRole("complementary").getByRole("link", { name: "Clients", exact: true }).click();
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeVisible();
  await page.reload();
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Sales & GSTR-1", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/2/2026-06/sales",
  );
  await page.goto("/app/clients");
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("restored-client.png"), fullPage: true });
  // Context route validates the persisted preference for an independently mounted tab.
  const tab = await page.context().newPage();
  await tab.route(/\/api\/workspace\/clients(?:\?.*)?$/, (route) =>
    route.fulfill({ json: { clients, user, can_edit: true, period: "2026-06" } }),
  );
  await tab.goto("/app/clients");
  await expect(tab.getByLabel("Switch client: Harbour Services", { exact: true })).toBeVisible();
  await tab.close();
});

test("explicit directory month wins over memory and client-specific tabs keep their URLs", async ({
  page,
}) => {
  await setup(page);
  await page.goto("/app/gst/2/2026-06/sales");
  await page.getByRole("complementary").getByRole("link", { name: "Clients", exact: true }).click();
  await page.goto("/app/clients?period=2026-04");
  await expect(page.getByLabel("Switch client: Harbour Services", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Sales & GSTR-1", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/2/2026-04/sales",
  );
  await expect(page.getByRole("link", { name: "Harbour Services", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/2/2026-04/sales",
  );
  await page.getByRole("link", { name: "Sales & GSTR-1", exact: true }).click();
  await page.getByRole("button", { name: "Previous month" }).click();
  await expect(page).toHaveURL("/app/gst/2/2026-03/sales");
  await page.goBack();
  await expect(page).toHaveURL("/app/gst/2/2026-04/sales");
  await page.goForward();
  await expect(page).toHaveURL("/app/gst/2/2026-03/sales");
});
