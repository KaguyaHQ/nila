import { test, expect } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";

function month(client = 1, period = "2026-06"): SalesWorkspace {
  return {
    client: {
      id: client,
      name: client === 1 ? "Breeze Tech" : "Second client",
    },
    clients: [
      { id: 1, name: "Breeze Tech" },
      { id: 2, name: "Second client" },
    ],
    user: { name: "Test accountant", org: "Test firm" },
    period,
    month_label: period === "2026-06" ? "June 2026" : "July 2026",
    can_upload: true,
    deadline: "2026-07-11",
    invoice_count: client === 1 && period === "2026-06" ? 1 : 0,
    review_count: 0,
    month_issue_count: 0,
    taxable: "₹1,000.00",
    tax: "₹180.00",
    uploads: { files: 1, unfinished: false },
    rows:
      client === 1 && period === "2026-06"
        ? [
            {
              id: "one",
              number: "REAL-101",
              date: "2026-06-10",
              customer: "Customer A",
              gstin: null,
              status: "ready",
              taxable: "₹1,000.00",
              tax: "₹180.00",
              reason: null,
              path: "/gst/1/2026-06/sales/invoices/one",
            },
          ]
        : [],
    sections: [
      {
        id: "b2b",
        label: "B2B",
        count: "1 invoice",
        value: "₹1,000.00",
        status: "Prepared",
        variant: "success",
        path: "/gst/1/2026-06/sales/b2b",
      },
    ],
    links: {
      upload: "/gst/upload?client_id=1&period=2026-06&kind=sales",
      uploads: "/gst/1/2026-06/sales/uploads",
      working: "/gst/1/2026-06/sales",
      purchases: "/gst/1/2026-06/purchases",
    },
  };
}

test("real workspace uses server data, changes month/client and preserves register URL", async ({
  page,
}) => {
  await page.route("**/api/workspace/sales/*/*", (route) => {
    const parts = new URL(route.request().url()).pathname.split("/");
    return route.fulfill({ json: month(Number(parts[4]), parts[5]) });
  });
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("heading", { name: "June 2026" })).toBeVisible();
  await expect(page.getByText("UI preview · sample data")).toHaveCount(0);
  await expect(page.getByText("Test accountant")).toBeVisible();
  await page.evaluate(() => {
    (window as any).sameDocument = true;
  });
  await page
    .getByRole("link", { name: "View sales register", exact: true })
    .click();
  await expect(page).toHaveURL(/\/app\/gst\/1\/2026-06\/sales\/register$/);
  expect(await page.evaluate(() => (window as any).sameDocument)).toBe(true);
  await expect(page.getByRole("link", { name: "REAL-101" })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-06/sales/invoices/one?filter=all",
  );
  await page
    .getByRole("textbox", { name: "Search customer, invoice or GSTIN" })
    .fill("Customer A");
  await page.reload();
  await expect(
    page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }),
  ).toHaveValue("Customer A");
  await page.getByRole("button", { name: "Next month", exact: true }).click();
  await expect(page).toHaveURL(/\/2026-07\/sales\/register/);
  await expect(page.getByRole("link", { name: "REAL-101" })).toHaveCount(0);
  await expect(
    page.getByText("No sales invoices yet", { exact: true }),
  ).toBeVisible();
  await page.getByLabel("Switch client: Breeze Tech", { exact: true }).click();
  await page.getByRole("option", { name: "Second client", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/gst\/2\/2026-07\/sales\/register/);
  await expect(page.getByLabel("Switch client: Second client", { exact: true })).toBeVisible();
});

test("loading, forbidden and expired session never masquerade as an empty register", async ({
  page,
}) => {
  let release!: () => void;
  const waiting = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/api/workspace/sales/*/*", async (route) => {
    await waiting;
    await route.fulfill({
      status: 403,
      json: { error: "You cannot access this firm." },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("status")).toHaveText("Loading sales…");
  release();
  await expect(page.getByRole("alert")).toHaveText(
    "You cannot access this firm.",
  );
  await expect(
    page.getByRole("heading", { name: "GSTR-1 summary" }),
  ).toHaveCount(0);
  await page.unrouteAll();
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill({ status: 401, json: { error: "Sign in to continue." } }),
  );
  await page.reload();
  await expect(
    page.getByRole("link", { name: "Sign in", exact: true }),
  ).toHaveAttribute("href", "/users/log_in");
});

test("failed requests can be retried and replace the error screen", async ({
  page,
}) => {
  let fails = true;
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill(
      fails
        ? { status: 500, json: { error: "Could not load sales." } }
        : { json: month() },
    ),
  );
  await page.goto("/app/gst/1/2026-06/sales");
  await expect(page.getByRole("alert")).toHaveText("Could not load sales.");
  fails = false;
  await page.getByRole("button", { name: "Try again" }).click();
  await expect(page.getByRole("heading", { name: "June 2026" })).toBeVisible();
});

test("excluded sources stay visible without opening a different invoice", async ({ page }) => {
  await page.route("**/api/workspace/sales/*/*", route => {
    const id = Number(new URL(route.request().url()).pathname.split("/")[4]);
    const data = month(id);
    data.rows.push({ id: "excluded", number: "EXCLUDED-1", date: null, customer: "Customer", gstin: null, status: "excluded", taxable: "₹1,000.00", tax: "₹180.00", reason: null, path: null });
    return route.fulfill({ json: data });
  });
  await page.goto("/app/gst/1/2026-06/sales/register");
  await expect(page.getByText("EXCLUDED-1", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "EXCLUDED-1" })).toHaveCount(0);
});
