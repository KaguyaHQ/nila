import { expect, test } from "@playwright/test";

test("route validation preserves text searches and rejects an unknown filter", async ({ page }) => {
  await page.goto("/app/sales/register?filter=not-a-filter&q=00123");
  const search = page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" });
  await expect(search).toHaveValue("00123");
  await page.getByRole("button", { name: "Clear search", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Showing 8 of 8 invoices");
  await search.fill("00123 & + / ? #");
  await expect.poll(() => new URL(page.url()).searchParams.get("q")).toBe("00123 & + / ? #");
  await page.reload();
  await expect(search).toHaveValue("00123 & + / ? #");
});

test("filters push history, typing replaces it, and back/forward retain the app document", async ({
  page,
}) => {
  await page.goto("/app/sales");
  await page.evaluate(() => {
    document.documentElement.dataset.routerMarker = "same-document";
  });
  await page.getByRole("link", { name: "Review invoices", exact: true }).click();
  await page.getByRole("button", { name: "All invoices 8", exact: true }).click();
  const search = page.getByRole("textbox", { name: "Search customer, invoice or GSTIN" });
  await search.fill("Philips");
  await expect(page.getByRole("status")).toHaveText("Showing 1 of 8 invoices");
  await page.goBack();
  await expect(page).toHaveURL(/\/app\/sales\/register\?filter=needs_review$/);
  await expect(search).toHaveValue("");
  await page.goForward();
  await expect(search).toHaveValue("Philips");
  await expect(page.getByRole("status")).toHaveText("Showing 1 of 8 invoices");
  expect(await page.locator("html").getAttribute("data-router-marker")).toBe("same-document");
});
