import { expect, test, type Page } from "@playwright/test";
import type { NoticesData } from "../src/lib/notices-api";

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

function fixture(): NoticesData {
  return {
    user: { name: "Vasanth", org: "Nila Dev CA" },
    permissions: { check: true, connect: true },
    checking: false,
    clients: [
      {
        id: 1,
        name: "Breeze Tech",
        gstin: "33AEWPH4158J1Z3",
        username: "breeze",
        state: "checked",
        last_checked_at: "2026-09-23T10:00:00Z",
        error: null,
        run_error: null,
      },
      {
        id: 2,
        name: "Simple Systems",
        gstin: "33AEWPH4158J1Z3",
        username: "simple",
        state: "expired",
        last_checked_at: "2026-09-01T10:00:00Z",
        error: null,
        run_error: "Reconnect GST",
      },
    ],
    run: {
      started_at: "2026-09-23T10:00:00Z",
      total: 2,
      checked: 1,
      pending: 0,
      failed: 1,
      retry_count: 0,
    },
    notices: [
      {
        id: 10,
        client_id: 1,
        client_name: "Breeze Tech",
        gstin: "33AEWPH4158J1Z3",
        reference: "ZD33092600123",
        type: "Reminder",
        issued_on: "2026-09-12",
        reply_due_on: "2026-09-30",
        period: "Aug 2026 – Aug 2026",
        new: true,
        documents: [
          { name: "Notice.pdf", type: "application/pdf", url: "/notices/10/documents/0" },
          { name: "Notes.txt", type: "text/plain", url: "/notices/10/documents/1" },
        ],
      },
      {
        id: 9,
        client_id: 2,
        client_name: "Simple Systems",
        gstin: "33AEWPH4158J1Z3",
        reference: "ZD33082600019",
        type: "Notice",
        issued_on: "2026-08-01",
        reply_due_on: null,
        period: null,
        new: false,
        documents: [],
      },
    ],
  };
}
async function setup(page: Page, data = fixture()) {
  await page.route("**/api/workspace/notices", (route) => route.fulfill({ json: data }));
  await page.route(/\/api\/workspace\/notices\/\d+$/, (route) => {
    const notice = data.notices.find(
      (n) => String(n.id) === route.request().url().split("/").pop(),
    );
    if (!notice)
      return route.fulfill({
        status: 404,
        json: { error: "Notice not found.", code: "not_found" },
      });
    const { new: _, ...detail } = notice;
    return route.fulfill({ json: { notice: detail } });
  });
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "notice-csrf";
      document.head.append(meta);
    }),
  );
  return data;
}

test("notice list keeps history visible, scopes client filters and shows failed coverage", async ({
  page,
}, info) => {
  await setup(page);
  await page.goto("/app/notices");
  await expect(page.getByRole("heading", { name: "Notices", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Notices", exact: true })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.getByText("1 of 2 clients checked")).toBeVisible();
  await page.keyboard.press("/");
  await expect(page.getByRole("textbox", { name: "Search notices" })).toBeFocused();
  await page.getByRole("heading", { name: "Notices", exact: true }).click();
  await expect(
    page.getByRole("region", { name: "New in latest check" }).getByText("ZD33092600123"),
  ).toBeVisible();
  await expect(
    page.getByRole("region", { name: "Saved notices" }).getByText("ZD33082600019"),
  ).toBeVisible();
  await page.screenshot({ path: info.outputPath("notices.png"), fullPage: true });
  await page.getByRole("combobox", { name: "Filter by client" }).selectOption("2");
  await expect(page).toHaveURL(/client_id=2/);
  await expect(page.getByText("ZD33092600123")).toHaveCount(0);
  await page.getByRole("textbox", { name: "Search notices" }).fill("not there");
  await expect(page.getByText("No saved notices match this filter.")).toBeVisible();
  await page.getByRole("button", { name: "1 unchecked" }).click();
  const sheet = page.getByRole("dialog", { name: "Client checks" });
  await expect(sheet.getByText("Simple Systems", { exact: true })).toBeVisible();
  await expect(sheet.getByText("Breeze Tech", { exact: true })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await expect(sheet).toBeHidden();
  await expect(page.getByRole("button", { name: "1 unchecked" })).toBeFocused();
});

test("all-client check blocks double submissions and failed writes retain notices", async ({
  page,
}) => {
  const data = await setup(page);
  let requests = 0;
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route("**/api/workspace/notices/check", async (route) => {
    requests++;
    expect(route.request().headers()["x-csrf-token"]).toBe("notice-csrf");
    await gate;
    await route.fulfill({
      status: 422,
      json: { error: "Could not start the check. Try again.", code: "request_failed" },
    });
  });
  await page.goto("/app/notices");
  const button = page.getByRole("button", { name: "Check all clients" });
  await button.click();
  await expect(button).toBeDisabled();
  expect(requests).toBe(1);
  release();
  await expect(page.getByRole("alert")).toContainText("Could not start");
  await expect(page.getByText(data.notices[0].reference)).toBeVisible();
  await expect(button).toBeEnabled();
});

test("OTP reconnect stays in React, checks after verification and clears the code", async ({
  page,
}, info) => {
  const data = await setup(page);
  let queued = 0;
  await page.route("**/api/workspace/notices/clients/2/otp", (route) => {
    expect(route.request().postDataJSON()).toEqual({ username: "simple" });
    return route.fulfill({ json: { challenge: "private-token" } });
  });
  await page.route("**/api/workspace/notices/clients/2/verify", (route) => {
    expect(route.request().postDataJSON()).toEqual({ challenge: "private-token", otp: "123456" });
    data.clients[1].state = "not_checked";
    return route.fulfill({ json: data });
  });
  await page.route("**/api/workspace/notices/clients/2/check", (route) => {
    queued++;
    data.clients[1].state = "checking";
    data.checking = true;
    return route.fulfill({ json: data });
  });
  await page.goto("/app/notices");
  await page.getByRole("button", { name: "1 unchecked" }).click();
  await page.getByRole("button", { name: "Reconnect GST", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Connect GST", exact: true });
  await expect(dialog.getByLabel("GST username")).toHaveValue("simple");
  await dialog.getByRole("button", { name: "Send OTP" }).click();
  const verification = page.getByRole("dialog", { name: "Verify GST connection" });
  await verification.getByLabel("Verification code").fill("123456");
  await verification.getByRole("button", { name: "Verify and check notices" }).click();
  await expect(verification).toBeHidden();
  await expect.poll(() => queued).toBe(1);
  await expect(
    page.getByRole("dialog", { name: "Client checks" }).getByRole("button", { name: "Checking…" }),
  ).toBeDisabled();
  await page.screenshot({ path: info.outputPath("client-checks.png"), fullPage: true });
});

test("viewer can read documents but cannot check or connect", async ({ page }) => {
  const data = fixture();
  data.permissions = { check: false, connect: false };
  await setup(page, data);
  await page.goto("/app/notices");
  await expect(page.getByRole("button", { name: "Check all clients" })).toBeDisabled();
  await page.getByRole("button", { name: "1 unchecked" }).click();
  await expect(page.getByRole("button", { name: "Reconnect GST", exact: true })).toBeDisabled();
  await expect(page.getByText("Ask the firm owner to connect GST.")).toBeVisible();
});

test("reader handles PDF failure, document switching and back without legacy navigation", async ({
  page,
}, info) => {
  await setup(page);
  await page.route("**/notices/10/documents/0", (route) =>
    route.fulfill({ status: 409, contentType: "text/plain", body: "GST login expired." }),
  );
  await page.goto("/app/notices");
  await page.getByRole("link", { name: "Open notice ZD33092600123" }).click();
  await expect(page).toHaveURL(/\/app\/notices\/10$/);
  await expect(page.getByRole("heading", { name: "Reminder", exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Open original" })).toHaveAttribute(
    "href",
    "/notices/10/documents/0",
  );
  await expect(page.locator("[data-pdf-status]")).not.toContainText("Loading PDF");
  await expect(
    page.getByText("Reply and closure status are not supplied.", { exact: false }),
  ).toBeVisible();
  await page.route("**/notices/10/documents/0", (route) =>
    route.fulfill({
      contentType: "application/pdf",
      body: previewPdf("GST notice reference ZD33092600123"),
    }),
  );
  await page.getByRole("button", { name: "Reload document" }).click();
  await expect(page.locator("[data-pdf-status]")).toBeHidden();
  await expect(page.locator("canvas").first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("notice-pdf.png"), fullPage: true });
  await page.getByLabel("Document", { exact: true }).selectOption("1");
  await expect(page.getByText("Preview unavailable", { exact: false })).toBeVisible();
  await page.screenshot({ path: info.outputPath("notice-detail.png"), fullPage: true });
  await page.getByRole("link", { name: "Back to notices" }).click();
  await expect(page).toHaveURL(/\/app\/notices\?client_id=1$/);
});

test("no documents and unknown notice render honest empty states", async ({ page }) => {
  await setup(page);
  await page.goto("/app/notices/9");
  await expect(page.getByText("No documents are available for this notice.")).toBeVisible();
  await page.goto("/app/notices/999");
  await expect(page.getByRole("alert")).toContainText("Notice not found");
});

test("empty firm and unauthorized request never claim all clear", async ({ page }) => {
  const data = fixture();
  data.clients = [];
  data.notices = [];
  data.run = null;
  await setup(page, data);
  await page.goto("/app/notices");
  await expect(page.getByText("Add clients to start checking for notices.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Check all clients" })).toBeDisabled();
  await page.route("**/api/workspace/notices", (route) =>
    route.fulfill({
      status: 401,
      json: { error: "Sign in to view notices.", code: "unauthenticated" },
    }),
  );
  await page.reload();
  await expect(page.getByRole("link", { name: "Sign in", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Check all clients" })).toHaveCount(0);
});
