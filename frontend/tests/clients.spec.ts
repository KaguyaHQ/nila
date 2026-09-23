import { expect, test, type Page } from "@playwright/test";
import type { ClientsDirectory, ImportRow } from "../src/lib/clients-api";

function directory(period = "2026-06", canEdit = true): ClientsDirectory {
  return {
    clients: [
      {
        id: 1,
        name: "Breeze Tech",
        gstin: "33AABCT3518Q1ZF",
        sales_path: `/gst/1/${period}/sales`,
      },
      { id: 2, name: "Harbour Services", gstin: null, sales_path: `/gst/2/${period}/sales` },
    ],
    user: { name: "Accountant", org: "Test firm" },
    can_edit: canEdit,
    can_manage_users: false,
    period,
  };
}
const rootApi = /\/api\/workspace\/clients(?:\?.*)?$/;
async function setup(page: Page, canEdit = true) {
  await page.route(rootApi, (route) =>
    route.fulfill({
      json: directory(
        new URL(route.request().url()).searchParams.get("period") ?? "2026-06",
        canEdit,
      ),
    }),
  );
  await page.route("**/api/workspace/clients/*/gst-connection", (route) =>
    route.fulfill({ json: { state: "not_connected", username: "", can_connect: canEdit } }),
  );
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "clients-csrf";
      document.head.append(meta);
    }),
  );
}

test("directory search preserves URL and period; slash focuses search without hijacking typing", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.goto("/app/clients?period=2026-04");
  await expect(page.getByRole("heading", { name: "Clients", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Breeze Tech", exact: true })).toHaveAttribute(
    "href",
    "/app/gst/1/2026-04/sales",
  );
  await expect(page.getByRole("link", { name: "Add client", exact: true })).toHaveAttribute(
    "href",
    "/app/clients/new?period=2026-04",
  );
  await page.keyboard.press("/");
  await expect(page.getByRole("textbox", { name: "Search clients" })).toBeFocused();
  await page.getByRole("textbox", { name: "Search clients" }).fill("Breeze");
  await expect(page.getByRole("status")).toHaveText("Showing 1 of 2 clients");
  await page.reload();
  await expect(page.getByRole("textbox", { name: "Search clients" })).toHaveValue("Breeze");
  await page.getByRole("textbox", { name: "Search clients" }).press("End");
  await page.getByRole("textbox", { name: "Search clients" }).press("/");
  await expect(page.getByRole("textbox", { name: "Search clients" })).toHaveValue("Breeze/");
  await expect(page.getByText("No clients match", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Clear search", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Showing 2 of 2 clients");
  await page.screenshot({ path: testInfo.outputPath("clients-desktop.png"), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("clients-narrow.png"), fullPage: true });
  await page.evaluate(() => {
    (window as unknown as { sameDocument: boolean }).sameDocument = true;
  });
  await page.getByRole("link", { name: "Edit Breeze Tech", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\/1\/edit\?period=2026-04$/);
  expect(
    await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument),
  ).toBe(true);
});

test("client row opens workspace while its edit action stays separate", async ({ page }) => {
  await setup(page);
  await page.goto("/app/clients?period=2026-04");
  const row = page
    .getByRole("row")
    .filter({ has: page.getByRole("link", { name: "Breeze Tech", exact: true }) });
  await expect(row).toHaveCSS("cursor", "pointer");
  await row.getByRole("cell").nth(1).click();
  await expect(page).toHaveURL("/app/gst/1/2026-04/sales");
  await page.goBack();
  await row.getByRole("link", { name: "Edit Breeze Tech", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\/1\/edit\?period=2026-04$/);
});

test("add form retains server validation errors and sends only client identity with CSRF", async ({
  page,
}) => {
  await setup(page);
  let writes = 0;
  await page.route(rootApi, async (route) => {
    if (route.request().method() === "GET") return route.fallback();
    writes++;
    expect(route.request().headers()["x-csrf-token"]).toBe("clients-csrf");
    const body = route.request().postDataJSON();
    expect(Object.keys(body.client).sort()).toEqual(["gstin", "name"]);
    await route.fulfill(
      writes === 1
        ? {
            status: 422,
            json: { error: "Check the client details.", errors: { gstin: ["is invalid"] } },
          }
        : { status: 201, json: { client: { id: 3, ...body.client }, can_edit: true } },
    );
  });
  await page.goto("/app/clients/new?period=2026-06");
  await page.getByLabel("Client name", { exact: true }).fill("New client");
  await page.getByLabel("GSTIN (optional)").fill("bad");
  await page.getByRole("button", { name: "Add client", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Check the client details.");
  await expect(page.getByLabel("GSTIN (optional)")).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByText("is invalid", { exact: true })).toBeVisible();
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("New client");
  await page.getByLabel("GSTIN (optional)").fill("");
  await page.getByRole("button", { name: "Add client", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\?period=2026-06$/);
  expect(writes).toBe(2);
});

test("edit loads real identity and keeps GST connection in React", async ({ page }) => {
  await setup(page);
  let writes = 0;
  let nextRead: Promise<void> | null = null;
  let releaseRead: (() => void) | undefined;
  await page.route("**/api/workspace/clients/1", async (route) => {
    if (route.request().method() === "PATCH") {
      writes++;
      expect(route.request().postDataJSON()).toEqual({
        client: { name: "Breeze Technology", gstin: "33AABCT3518Q1ZF" },
      });
      return route.fulfill({
        json: {
          client: { id: 1, name: "Breeze Technology", gstin: "33AABCT3518Q1ZF" },
          can_edit: true,
        },
      });
    }
    if (nextRead) await nextRead;
    return route.fulfill({
      json: {
        client: { ...directory().clients[0], name: writes ? "Changed elsewhere" : "Breeze Tech" },
        can_edit: true,
      },
    });
  });
  await page.goto("/app/clients/1/edit?period=2026-06");
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("Breeze Tech");
  await expect(page.getByRole("region", { name: "GST connection" })).toBeVisible();
  await expect(page.getByRole("link", { name: "GST and Tally connections" })).toHaveCount(0);
  await page.getByLabel("Client name", { exact: true }).fill("Breeze Technology");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page).toHaveURL(/\/clients\?period=2026-06$/);
  expect(writes).toBe(1);
  nextRead = new Promise<void>((resolve) => {
    releaseRead = resolve;
  });
  await page.getByRole("link", { name: "Edit Breeze Tech", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Loading client…");
  await expect(page.getByLabel("Client name", { exact: true })).toHaveCount(0);
  releaseRead!();
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("Changed elsewhere");
});

test("Excel import keeps skipped and invalid rows visible and reports only confirmed save results", async ({
  page,
}) => {
  await setup(page);
  const rows: ImportRow[] = [
    {
      row: 2,
      name: "New client",
      gstin: "33AABCT3518Q1ZF",
      gst_username: "newclient",
      status: "ready",
      message: "Ready to add",
    },
    {
      row: 3,
      name: "Breeze Tech",
      gstin: null,
      status: "skip",
      message: "Client name already exists. Check the existing client.",
    },
    {
      row: 4,
      name: "Broken GSTIN",
      gstin: "INVALID",
      status: "invalid",
      message: "GSTIN is invalid.",
    },
  ];
  await page.route("**/api/workspace/clients/import/preview", (route) => {
    expect(route.request().headers()["x-csrf-token"]).toBe("clients-csrf");
    expect(route.request().headers()["content-type"]).toContain("multipart/form-data; boundary=");
    expect(route.request().postData()).toContain('name="file"; filename="clients.xlsx"');
    return route.fulfill({ json: { rows, token: "preview-token", ready_count: 1 } });
  });
  let commits = 0;
  await page.route("**/api/workspace/clients/import", (route) => {
    expect(route.request().postDataJSON()).toEqual({ token: "preview-token" });
    commits++;
    return route.fulfill(
      commits === 1
        ? { status: 503, json: { error: "Could not confirm this import. Try again." } }
        : {
            json: {
              rows: [{ ...rows[0], status: "added", message: "Added" }, ...rows.slice(1)],
              added_count: 1,
              skipped_count: 1,
              invalid_count: 1,
            },
          },
    );
  });
  await page.goto("/app/clients/import?period=2026-06");
  await expect(page.getByRole("link", { name: "Download template" })).toHaveAttribute(
    "href",
    "/clients/import-template.xlsx",
  );
  await page.getByLabel("Client list (.xlsx)").setInputFiles({
    name: "clients.xlsx",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    buffer: Buffer.from("workbook fixture"),
  });
  await page.getByRole("button", { name: "Preview clients", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("1 ready to add · 1 skipped · 1 invalid");
  await expect(page.getByRole("columnheader", { name: "GST username" })).toBeVisible();
  await expect(page.getByText("newclient", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Add 1 client", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Could not confirm this import. Try again.");
  await expect(page.getByRole("heading", { name: "Import results", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Add 1 client", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Import results", exact: true })).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("1 added · 1 skipped · 1 invalid");
  await expect(page.getByText("GSTIN is invalid.", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Add 1 client", exact: true })).toHaveCount(0);
});

test("view-only role cannot add or import and permission failures never look empty", async ({
  page,
}) => {
  await setup(page, false);
  await page.goto("/app/clients?period=2026-06");
  await expect(page.getByRole("button", { name: "Add client", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Import Excel", exact: true })).toBeDisabled();
  await page.goto("/app/clients/new?period=2026-06");
  await expect(page.getByLabel("Client name", { exact: true })).toBeDisabled();
  await page.goto("/app/clients/import?period=2026-06");
  await expect(page.getByLabel("Client list (.xlsx)")).toBeDisabled();
  await page.route(rootApi, (route) =>
    route.fulfill({ status: 403, json: { error: "You cannot access these clients." } }),
  );
  await page.reload();
  await expect(page.getByRole("alert")).toHaveText("You cannot access these clients.");
  await expect(page.getByText("No clients yet", { exact: true })).toHaveCount(0);
});

test("choosing another workbook clears a failed preview before retrying", async ({ page }) => {
  await setup(page);
  let previews = 0;
  await page.route("**/api/workspace/clients/import/preview", (route) => {
    previews++;
    return route.fulfill(
      previews === 1
        ? { status: 422, json: { error: "Cannot read this workbook." } }
        : { json: { rows: [], token: "replacement-token", ready_count: 0 } },
    );
  });
  await page.goto("/app/clients/import?period=2026-06");
  const picker = page.getByLabel("Client list (.xlsx)");
  await picker.setInputFiles({
    name: "broken.xlsx",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    buffer: Buffer.from("broken"),
  });
  await page.getByRole("button", { name: "Preview clients", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Cannot read this workbook.");
  await expect(picker).toBeEnabled();
  await picker.setInputFiles({
    name: "replacement.xlsx",
    mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    buffer: Buffer.from("replacement"),
  });
  await expect(page.getByRole("alert")).toHaveCount(0);
  await page.getByRole("button", { name: "Preview clients", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Preview", exact: true })).toBeVisible();
  expect(previews).toBe(2);
});

test("client GST connects in place without fetching 2B and retains identity edits", async ({
  page,
}, info) => {
  await setup(page);
  await page.route("**/api/workspace/clients/1", (route) =>
    route.fulfill({ json: { client: directory().clients[0], can_edit: true } }),
  );
  await page.route("**/api/workspace/clients/1/gst-connection", (route) =>
    route.fulfill({ json: { state: "expired", username: "breeze", can_connect: true } }),
  );
  let writes = 0;
  await page.route("**/api/workspace/clients/1/gst-connection/otp", (route) => {
    expect(route.request().headers()["x-csrf-token"]).toBe("clients-csrf");
    expect(route.request().postDataJSON()).toEqual({ username: "breeze" });
    return route.fulfill({ json: { challenge: "encrypted", username: "breeze", expires_in: 900 } });
  });
  await page.route("**/api/workspace/clients/1/gst-connection/verify", (route) => {
    writes++;
    expect(route.request().postDataJSON()).toEqual({ challenge: "encrypted", otp: "123456" });
    return route.fulfill({ json: { state: "connected", username: "breeze", can_connect: true } });
  });
  const fetches: string[] = [];
  page.on("request", (request) => {
    if (request.url().includes("/api/") && request.url().includes("/gstr2b"))
      fetches.push(request.url());
  });
  await page.goto("/app/clients/1/edit");
  await expect(page.getByText("GST login expired")).toBeVisible();
  await page.getByLabel("Client name", { exact: true }).fill("Unsaved name");
  await page.getByRole("button", { name: "Reconnect", exact: true }).click();
  await expect(page.getByLabel("GST username")).toHaveValue("breeze");
  await page.getByRole("button", { name: "Send OTP", exact: true }).click();
  await page.getByLabel("Verification code", { exact: true }).fill("123456");
  await page.screenshot({ path: info.outputPath("gst-otp.png") });
  await page.getByRole("button", { name: "Verify connection", exact: true }).click();
  await expect(page.getByRole("dialog")).toBeHidden();
  await expect(page.getByText("GST portal connected")).toBeVisible();
  await expect(page.getByRole("button", { name: "Reconnect", exact: true })).toBeFocused();
  await expect(page.getByLabel("Client name", { exact: true })).toHaveValue("Unsaved name");
  expect(writes).toBe(1);
  expect(fetches).toEqual([]);
  await expect(page).toHaveURL(/\/app\/clients\/1\/edit$/);
  await page.screenshot({ path: info.outputPath("client-gst-connected.png") });
});

test("closing pending client OTP discards the response and missing GSTIN disables connection", async ({
  page,
}) => {
  await setup(page);
  await page.route("**/api/workspace/clients/1", (route) =>
    route.fulfill({ json: { client: directory().clients[0], can_edit: true } }),
  );
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  await page.route("**/api/workspace/clients/1/gst-connection/otp", async (route) => {
    await gate;
    await route
      .fulfill({ json: { challenge: "old", username: "old", expires_in: 900 } })
      .catch(() => {});
  });
  await page.goto("/app/clients/1/edit");
  await page.getByRole("button", { name: "Connect GST", exact: true }).click();
  await page.getByLabel("GST username").fill("old");
  await page.getByRole("button", { name: "Send OTP" }).click();
  await expect(page.getByLabel("GST username")).toBeDisabled();
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Connect GST", exact: true }).click();
  release();
  await expect(page.getByLabel("GST username")).toHaveValue("");
  await expect(page.getByLabel("Verification code")).toHaveCount(0);
  await page.keyboard.press("Escape");
  await page.route("**/api/workspace/clients/1/gst-connection", (route) =>
    route.fulfill({ json: { state: "missing_gstin", username: "", can_connect: true } }),
  );
  await page.reload();
  await expect(page.getByText("Save a valid GSTIN above to connect.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Connect GST", exact: true })).toHaveCount(0);
});
