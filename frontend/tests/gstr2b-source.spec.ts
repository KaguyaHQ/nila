import { expect, test, type Page } from "@playwright/test";
import type { Gstr2bState } from "../src/lib/gstr2b-api";

const path = "/api/workspace/purchases/1/2026-06/gstr2b";

test("a delayed old status read cannot stop fresh fetch preparation", async ({ page }) => {
  await setup(page);
  let holdNext = false;
  let oldReadStarted = false;
  let imports = 0;
  let current = state();
  let releaseOld!: () => void;
  const held = new Promise<void>((resolve) => {
    releaseOld = resolve;
  });
  await page.route(`**${path}`, async (route) => {
    const snapshot = current;
    if (holdNext) {
      holdNext = false;
      oldReadStarted = true;
      await held;
    }
    await route.fulfill({ json: snapshot }).catch(() => {});
  });
  await page.route(`**${path}/fetch`, async (route) => {
    current = {
      ...state(),
      statement: {
        id: 1,
        status: "ready",
        fetched_at: "2026-06-20T10:00:00Z",
        last_error: null,
        failure_reason: null,
        download_url: null,
      },
      import: { needed: true, status: null, error: null },
    };
    await route.fulfill({ status: 202, json: { ...state(), fetching: true } });
    releaseOld();
  });
  await page.route(`**${path}/import`, (route) => {
    imports++;
    current = { ...current, import: { needed: false, status: "extracted", error: null } };
    return route.fulfill({ status: 202, json: current });
  });
  await page.goto("/app/gst/1/2026-06/purchases");
  await expect(page.getByRole("button", { name: "Fetch GSTR-2B", exact: true })).toBeEnabled();
  // Remount with cached data: the button is usable while a stale GET is pending.
  await page.getByRole("link", { name: "View register", exact: true }).last().click();
  holdNext = true;
  await page.goBack();
  await expect.poll(() => oldReadStarted).toBe(true);
  await page.getByRole("button", { name: "Fetch GSTR-2B", exact: true }).click();
  await expect.poll(() => imports).toBe(1);
  await expect(page.getByRole("button", { name: "Refresh GSTR-2B", exact: true })).toBeEnabled();
});
function state(): Gstr2bState {
  return {
    client: { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF" },
    period: "2026-06",
    connection: { state: "connected", username: "breeze" },
    permissions: { fetch: true, connect: true, export: true },
    statement: null,
    fetching: false,
    import: { needed: false, status: null, error: null },
    availability_hint: null,
  };
}
async function setup(page: Page) {
  await page.route("**/api/workspace/purchases/*/*?*", (route) =>
    route.fulfill({
      json: {
        client: { id: 1, name: "Breeze Tech", gstin: "33AABCT3518Q1ZF" },
        clients: [{ id: 1, name: "Breeze Tech" }],
        user: { name: "Accountant", org: "Test firm" },
        period: new URL(route.request().url()).pathname.split("/").at(-1),
        month_label: "June 2026",
        can_edit: true,
        signed_off: false,
        lock_reason: null,
        processing: false,
        inputs: {
          books: { present: false, count: 0, tax: "₹0.00" },
          portal: {
            present: true,
            count: 46,
            tax: "₹1,800.00",
            fetching: false,
            needs_import: false,
          },
        },
        overview: {
          complete: false,
          comparison_available: false,
          remaining: 0,
          buckets: [],
          itc: {
            recorded: false,
            claim: "₹0.00",
            later: "₹0.00",
            excluded: "₹0.00",
            pending: "₹1,800.00",
            carried_count: 0,
            stale_count: 0,
          },
        },
        rows: [],
        carried: [],
        filters: [],
        filter: "register",
        q: "",
        working: { enabled: false, url: "/draft.xlsx", status: "Draft working", reason: null },
        links: {
          import_excel: "/legacy-import",
          uploads: "/legacy-uploads",
          review: "/gst/1/2026-06/purchases/review",
          treatment: "/gst/1/2026-06/purchases/review?filter=treatment",
          carried: "",
          portal: "/old-portal",
        },
        notice: "",
      },
    }),
  );
}

test("fetch and prepare remain in React, preserve source totals and show failure", async ({
  page,
}, testInfo) => {
  await setup(page);
  let current = state();
  await page.route(`**${path}`, (route) => route.fulfill({ json: current }));
  await page.route(`**${path}/fetch`, (route) => {
    current = {
      ...current,
      statement: {
        id: 1,
        status: "ready",
        fetched_at: "2026-06-20T10:00:00Z",
        last_error: null,
        failure_reason: null,
        download_url: "/source.json",
      },
      import: { needed: true, status: null, error: null },
    };
    return route.fulfill({ status: 202, json: current });
  });
  await page.route(`**${path}/import`, (route) =>
    route.fulfill({
      status: 422,
      json: { error: "Could not prepare the saved statement. Try again.", code: "import_failed" },
    }),
  );
  await page.goto("/app/gst/1/2026-06/purchases");
  await page.getByRole("button", { name: "Fetch GSTR-2B", exact: true }).click();
  await expect(page.getByText("Fetched 20 Jun 2026", { exact: false })).toBeVisible();
  await expect(page.getByRole("alert")).toContainText("Could not prepare");
  await expect(page.getByText("₹1,800.00", { exact: false }).first()).toBeVisible();
  await expect(page).toHaveURL(/\/app\/gst\/1\/2026-06\/purchases$/);
  await page.getByRole("button", { name: "GSTR-2B source actions" }).click();
  await expect(page.getByRole("menuitem", { name: "Download source JSON" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menuitem", { name: "Download source JSON" })).not.toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("gstr2b-source.png"), fullPage: true });
});

test("reconnect validates OTP, preserves input on error and verifies without old app", async ({
  page,
}, testInfo) => {
  await setup(page);
  let current: Gstr2bState = { ...state(), connection: { state: "expired", username: "breeze" } };
  await page.route(`**${path}`, (route) => route.fulfill({ json: current }));
  await page.route(`**${path}/otp`, (route) => {
    expect(route.request().postDataJSON()).toEqual({ username: "breeze" });
    return route.fulfill({ json: { challenge: "opaque", username: "breeze", expires_in: 900 } });
  });
  let attempts = 0;
  await page.route(`**${path}/verify`, (route) => {
    expect(route.request().postDataJSON()).toEqual({ challenge: "opaque", otp: "123456" });
    if (++attempts === 1)
      return route.fulfill({
        status: 422,
        json: { error: "That OTP is incorrect.", code: "invalid_otp" },
      });
    current = { ...state(), fetching: true };
    return route.fulfill({ status: 202, json: current });
  });
  await page.goto("/app/gst/1/2026-06/purchases");
  await page.getByRole("button", { name: "Reconnect GST" }).click();
  await expect(page.getByLabel("GST username")).toHaveValue("breeze");
  await page.getByRole("button", { name: "Send OTP", exact: true }).click();
  await page.getByLabel("Verification code", { exact: true }).fill("123");
  await expect(page.getByRole("button", { name: "Verify and fetch GSTR-2B" })).toBeDisabled();
  await page.getByLabel("Verification code", { exact: true }).fill("123456");
  await page.getByRole("button", { name: "Verify and fetch GSTR-2B" }).click();
  await expect(page.getByRole("dialog").getByRole("alert")).toHaveText("That OTP is incorrect.");
  await page.screenshot({ path: testInfo.outputPath("gstr2b-otp.png"), fullPage: true });
  await page.getByRole("button", { name: "Verify and fetch GSTR-2B" }).click();
  await expect(page.getByRole("dialog")).not.toBeVisible();
  await expect(page.getByRole("button", { name: "Fetching GSTR-2B…" })).toBeDisabled();
});

test("month change discards connection dialog state", async ({ page }) => {
  await setup(page);
  await page.route("**/gstr2b", (route) =>
    route.fulfill({ json: { ...state(), connection: { state: "not_connected", username: null } } }),
  );
  await page.goto("/app/gst/1/2026-06/purchases");
  await page.getByRole("button", { name: "Connect GST", exact: true }).click();
  await page.getByLabel("GST username").fill("private-user");
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "Previous month" }).click();
  await page.getByRole("button", { name: "Connect GST", exact: true }).click();
  await expect(page.getByLabel("GST username")).toHaveValue("");
});

test("failed refresh keeps saved JSON and never imports the retained snapshot", async ({
  page,
}) => {
  await setup(page);
  let saved: Gstr2bState = {
    ...state(),
    statement: {
      id: 1,
      status: "ready",
      fetched_at: "2026-06-20T10:00:00Z",
      last_error: null,
      failure_reason: null,
      download_url: "/source.json",
    },
    import: { needed: true, status: null, error: null },
  };
  let imports = 0;
  await page.route(`**${path}`, (route) => route.fulfill({ json: saved }));
  await page.route(`**${path}/fetch`, (route) => {
    saved = {
      ...saved,
      statement: {
        ...saved.statement!,
        status: "failed",
        last_error: "GST did not return a complete statement.",
      },
    };
    return route.fulfill({ status: 202, json: saved });
  });
  await page.route(`**${path}/import`, (route) => {
    imports++;
    return route.fulfill({ json: saved });
  });
  await page.goto("/app/gst/1/2026-06/purchases");
  await page.getByRole("button", { name: "Refresh GSTR-2B" }).click();
  await expect(page.getByRole("alert")).toHaveText("GST did not return a complete statement.");
  await expect(page.getByRole("button", { name: "Prepare for review" })).toBeVisible();
  expect(imports).toBe(0);
  await page.getByRole("button", { name: "GSTR-2B source actions" }).click();
  await expect(page.getByRole("menuitem", { name: "Download source JSON" })).toBeVisible();
});

test("closing a pending OTP request cannot replace a reopened connection dialog", async ({
  page,
}) => {
  await setup(page);
  await page.route(`**${path}`, (route) =>
    route.fulfill({ json: { ...state(), connection: { state: "not_connected", username: null } } }),
  );
  let attempts = 0;
  let oldRequestFinished = false;
  let releaseOld!: () => void;
  const held = new Promise<void>((resolve) => {
    releaseOld = resolve;
  });
  await page.route(`**${path}/otp`, async (route) => {
    attempts++;
    if (attempts === 1) await held;
    await route
      .fulfill({ json: { challenge: "old-challenge", username: "first-user", expires_in: 900 } })
      .catch(() => {});
    oldRequestFinished = true;
  });
  await page.goto("/app/gst/1/2026-06/purchases");
  await page.getByRole("button", { name: "Connect GST", exact: true }).click();
  await page.getByLabel("GST username").fill("first-user");
  await page.getByRole("button", { name: "Send OTP", exact: true }).click();
  await expect.poll(() => attempts).toBe(1);
  await expect(page.getByRole("button", { name: "Please wait…", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "Connect GST", exact: true }).click();
  await page.getByLabel("GST username").fill("second-user");
  releaseOld();
  await expect.poll(() => oldRequestFinished).toBe(true);
  await expect(page.getByLabel("GST username")).toHaveValue("second-user");
  await expect(page.getByRole("button", { name: "Send OTP", exact: true })).toBeEnabled();
  await expect(page.getByLabel("Verification code", { exact: true })).toHaveCount(0);
  expect(attempts).toBe(1);
});
