import { expect, test, type Page } from "@playwright/test";

const clientsApi = /\/api\/workspace\/clients(?:\?.*)?$/;

async function openNewClient(page: Page) {
  await page.route(clientsApi, (route) =>
    route.fulfill({
      json: {
        clients: [],
        user: { name: "Accountant", org: "Firm" },
        can_edit: true,
        period: "2026-06",
      },
    }),
  );
  await page.goto("/app/clients/new?period=2026-06");
  await page.getByLabel("Client name", { exact: true }).fill("New client");
}

test("rapid submits create only one client and stay pending until the server confirms", async ({
  page,
}) => {
  await openNewClient(page);
  let writes = 0;
  let release!: () => void;
  const response = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route(clientsApi, async (route) => {
    if (route.request().method() === "GET") return route.fallback();
    writes++;
    await response;
    await route.fulfill({
      status: 201,
      json: { client: { id: 3, name: "New client", gstin: null }, can_edit: true },
    });
  });

  try {
    await page.getByLabel("Client name", { exact: true }).evaluate((input) => {
      const form = (input as HTMLInputElement).form!;
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    });
    await expect.poll(() => writes).toBe(1);
    await expect(page.getByRole("button", { name: "Saving…", exact: true })).toBeDisabled();
    await expect(page).toHaveURL(/\/clients\/new\?period=2026-06$/);
  } finally {
    release();
  }
  await expect(page).toHaveURL(/\/clients\?period=2026-06$/);
  expect(writes).toBe(1);
});

test("a failed offline save keeps edits and requires an explicit retry", async ({ page }) => {
  await openNewClient(page);
  let writes = 0;
  await page.route(clientsApi, async (route) => {
    if (route.request().method() === "GET") return route.fallback();
    writes++;
    if (writes === 1) return route.abort("internetdisconnected");
    return route.fulfill({
      status: 201,
      json: { client: { id: 3, name: "New client", gstin: null }, can_edit: true },
    });
  });
  await page.evaluate(() => window.dispatchEvent(new Event("offline")));
  await page.getByRole("button", { name: "Add client", exact: true }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("New client");
  await expect(page.getByRole("button", { name: "Add client", exact: true })).toBeEnabled();
  expect(writes).toBe(1);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await page.getByRole("button", { name: "Add client", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\?period=2026-06$/);
  expect(writes).toBe(2);
});
