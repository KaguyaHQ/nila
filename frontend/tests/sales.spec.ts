import { test, expect } from "@playwright/test";

test("summary and register navigate without replacing the document", async ({ page }) => {
  await page.goto("/sales");
  await expect(page.getByRole("heading", { name: "June 2026", exact: true })).toBeVisible();
  await expect(page.locator("tbody tr")).toHaveCount(11);
  await page.evaluate(() => {
    (window as unknown as { navigationMarker: string }).navigationMarker = "same-document";
  });
  await page.getByRole("link", { name: "Review invoices", exact: true }).click();
  await expect(page).toHaveURL(/\/sales\/register\?filter=needs_review$/);
  await expect(page.getByRole("status")).toHaveText("Showing 5 of 8 invoices");
  await page.getByRole("button", { name: "All invoices 8", exact: true }).click();
  await expect(page.locator("tbody tr")).toHaveCount(8);
  await page.getByRole("link", { name: "Sales summary", exact: true }).click();
  expect(
    await page.evaluate(() => (window as unknown as { navigationMarker: string }).navigationMarker),
  ).toBe("same-document");
  await page.goBack();
  await expect(page.getByRole("heading", { name: "Sales register", exact: true })).toBeVisible();
});

test("register search survives refresh and sample dialog restores focus", async ({ page }) => {
  await page.goto("/sales/register?filter=ready");
  await expect(page.getByRole("status")).toHaveText("Showing 3 of 8 invoices");
  await page.getByRole("button", { name: "All invoices 8", exact: true }).click();
  await page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }).fill("Philips");
  await expect(page.getByRole("status")).toHaveText("Showing 1 of 8 invoices");
  await page.reload();
  await expect(
    page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" }),
  ).toHaveValue("Philips");
  const opener = page.getByRole("button", { name: "View sample invoice 38/2026-27", exact: true });
  await opener.click();
  await expect(page.getByRole("dialog")).toContainText("₹36,580.00");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(opener).toBeFocused();
  await page
    .getByRole("textbox", { name: "Search customer, invoice or GSTIN" })
    .fill("does-not-exist");
  await expect(page.getByText("No invoices match", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Clear filters", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Showing 8 of 8 invoices");
});

test("PDF selection stays local and survives navigation to history", async ({ page }) => {
  const writes: string[] = [];
  page.on("request", (request) => {
    if (["POST", "PUT", "PATCH", "DELETE"].includes(request.method())) writes.push(request.url());
  });
  await page.goto("/sales/upload");
  const picker = page.getByLabel("Choose sales PDF files");
  await picker.setInputFiles([
    {
      name: "sales.pdf",
      mimeType: "application/pdf",
      buffer: Buffer.from("%PDF-1.4\npreview fixture"),
    },
    {
      name: "books.xlsx",
      mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      buffer: Buffer.from("not a pdf"),
    },
  ]);
  await expect(page.getByRole("alert")).toContainText("books.xlsx: choose a PDF file.");
  await expect(page.getByRole("heading", { name: "1 file selected", exact: true })).toBeVisible();
  await page.getByRole("link", { name: "View uploads", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Selected in this browser", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("sales.pdf", { exact: true })).toBeVisible();
  await page.getByRole("link", { name: "Manage files", exact: true }).click();
  await page.getByRole("button", { name: "Remove sales.pdf", exact: true }).click();
  await expect(page.getByRole("heading", { name: "1 file selected", exact: true })).toHaveCount(0);
  expect(writes).toEqual([]);
});

test("PDF drop works and empty PDFs are rejected", async ({ page }) => {
  await page.goto("/sales/upload");
  const transfer = await page.evaluateHandle(() => {
    const data = new DataTransfer();
    data.items.add(new File(["%PDF-1.4\npreview"], "dropped.pdf", { type: "application/pdf" }));
    data.items.add(new File([], "empty.pdf", { type: "application/pdf" }));
    return data;
  });
  await page
    .getByRole("heading", { name: "Drop your sales PDFs here", exact: true })
    .dispatchEvent("drop", { dataTransfer: transfer });
  await expect(page.getByText("dropped.pdf", { exact: true })).toBeVisible();
  await expect(page.getByRole("alert")).toContainText("empty.pdf: this file is empty.");
});

test("direct routes and narrow layout remain usable", async ({ page }) => {
  await page.setViewportSize({ width: 800, height: 1000 });
  for (const route of ["/sales", "/sales/register", "/sales/upload", "/sales/uploads"]) {
    await page.goto(route);
    await expect(page.locator("h1")).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(
      true,
    );
  }
  await page.goto("/unknown");
  await expect(page.getByRole("heading", { name: "Page not found" })).toBeVisible();
});
