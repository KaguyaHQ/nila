import { expect, type Page, test } from "@playwright/test";
import type { SalesWorkspace } from "../src/lib/sales-api";

function workspace(client = 1): SalesWorkspace {
  return {
    details: {},
    exports: { items: [], blockers: [], status: "No exports available." },
    client: { id: client, name: client === 1 ? "Breeze Tech" : "Second client" },
    clients: [
      { id: 1, name: "Breeze Tech" },
      { id: 2, name: "Second client" },
    ],
    user: { name: "Accountant", org: "Test firm" },
    period: "2026-06",
    month_label: "June 2026",
    deadline: "2026-07-11",
    invoice_count: 0,
    review_count: 0,
    month_issue_count: 0,
    can_upload: true,
    taxable: "—",
    tax: "—",
    uploads: { files: 0, unfinished: false },
    rows: [],
    sections: [],
    links: {
      upload: "/gst/1/2026-06/sales/upload",
      uploads: "/gst/1/2026-06/sales/uploads",
      working: "/gst/1/2026-06/sales",
      purchases: "/gst/1/2026-06/purchases",
    },
  };
}

const pdf = (name: string) => ({
  name,
  mimeType: "application/pdf",
  buffer: Buffer.from("%PDF-1.4\nsales bill"),
});

async function setup(page: Page) {
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill({
      json: workspace(Number(new URL(route.request().url()).pathname.split("/")[4])),
    }),
  );

  await page.route("**/api/workspace/sales/*/*/uploads/batch-1", (route) =>
    route.fulfill({ json: { id: "batch-1", processing: true, files: [] } }),
  );

  await page.addInitScript(() => {
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "test-csrf";
      document.head.append(meta);
    });
  });
}

test("failed PUT resumes remaining PDFs and uncertain commit retries the same token", async ({
  page,
}) => {
  await setup(page);
  let prepares = 0;
  let firstPuts = 0;
  let secondPuts = 0;
  const commits: string[] = [];
  await page.route("**/uploads/prepare", async (route) => {
    prepares++;
    expect(route.request().headers()["x-csrf-token"]).toBe("test-csrf");
    expect(
      route
        .request()
        .postDataJSON()
        .files.map((file: { name: string }) => file.name),
    ).toEqual(["first.pdf", "second.pdf"]);
    await route.fulfill({
      json: {
        token: "same-token",
        files: [
          { name: "first.pdf", url: "http://127.0.0.1:5174/storage/first" },
          { name: "second.pdf", url: "http://127.0.0.1:5174/storage/second" },
        ],
      },
    });
  });
  await page.route("**/storage/*", async (route) => {
    expect(route.request().method()).toBe("PUT");
    expect(route.request().headers()["content-type"]).toBe("application/pdf");
    if (route.request().url().endsWith("first")) {
      firstPuts++;
      await route.fulfill({ status: 200, body: "" });
    } else {
      secondPuts++;
      await route.fulfill({ status: secondPuts === 1 ? 503 : 200, body: "" });
    }
  });
  await page.route("**/api/workspace/sales/*/*/uploads", async (route) => {
    if (route.request().method() === "POST") {
      expect(route.request().headers()["x-csrf-token"]).toBe("test-csrf");
      commits.push(route.request().postDataJSON().token);
      await route.fulfill(
        commits.length === 1
          ? { status: 503, json: { error: "Connection interrupted while saving." } }
          : { json: { ok: true, batch_ref: "batch-1" } },
      );
    } else await route.fulfill({ json: { batches: [], processing: false } });
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page
    .getByLabel("Choose sales PDF files")
    .setInputFiles([pdf("first.pdf"), pdf("second.pdf")]);
  await page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Couldn't upload second.pdf");
  await expect(
    page.getByRole("progressbar", { name: "Upload progress for first.pdf" }),
  ).toHaveAttribute("aria-valuenow", "100");
  await expect(page.getByRole("button", { name: "Add more", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Retry upload", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("Connection interrupted while saving");
  await expect(page.getByRole("status")).toContainText("Retry to confirm");
  await page.getByRole("link", { name: "View uploads", exact: true }).click();
  await page.getByRole("button", { name: "Add invoices", exact: true }).click();
  await expect(page.getByRole("button", { name: "Retry upload", exact: true })).toBeVisible();
  await page.evaluate(() => {
    (window as unknown as { sameDocument: boolean }).sameDocument = true;
  });
  await page.getByRole("button", { name: "Retry upload", exact: true }).click();

  await expect(page).toHaveURL(/\/sales\/uploads\/batch-1$/);

  await expect(page.getByRole("heading", { name: "Upload results" })).toBeVisible();
  expect(prepares).toBe(1);
  expect(firstPuts).toBe(1);
  expect(secondPuts).toBe(2);
  expect(commits).toEqual(["same-token", "same-token"]);
  expect(
    await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument),
  ).toBe(true);
});

test("PDF validation prevents invalid writes and switching client clears the old selection", async ({
  page,
}, info) => {
  await setup(page);
  const writes: string[] = [];
  page.on("request", (request) => {
    if (request.method() === "POST") writes.push(request.url());
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.screenshot({ path: info.outputPath("upload-modal.png") });
  await page
    .getByLabel("Choose sales PDF files")
    .setInputFiles([
      { name: "empty.pdf", mimeType: "application/pdf", buffer: Buffer.from("") },
      { name: "invoice.csv", mimeType: "text/csv", buffer: Buffer.from("csv") },
      pdf("sales.pdf"),
    ]);
  await expect(page.getByRole("alert")).toContainText("this file is empty");
  await expect(page.getByRole("alert")).toContainText("choose a PDF file");
  await expect(page.getByRole("heading", { name: "1 file selected" })).toBeVisible();
  await page.getByRole("button", { name: "Close" }).click();
  await page.getByLabel("Switch client: Breeze Tech", { exact: true }).click();
  await page.getByRole("option", { name: "Second client", exact: true }).click();
  await page.getByRole("button", { name: "Add invoices", exact: true }).click();
  await expect(page).toHaveURL(/\/gst\/2\/2026-06\/sales\?upload=invoices$/);
  await expect(page.getByText("sales.pdf", { exact: true })).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }),
  ).toBeDisabled();
  expect(writes).toEqual([]);
});

test("outside click and Escape close the upload dialog without reopening it", async ({ page }) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales");
  const dialog = page.getByRole("dialog", { name: "Add sales bills" });
  const add = page.getByRole("button", { name: "Add invoices", exact: true });

  await add.click();
  await expect(dialog).toBeVisible();
  const backdrop = page.locator('[data-slot="dialog-overlay"]');
  await expect(backdrop).toBeVisible();
  const durations = await page.evaluate(() => {
    const overlay = document.querySelector('[data-slot="dialog-overlay"]');
    const popup = document.querySelector('[data-slot="dialog-content"]');
    return [overlay, popup].map((element) =>
      element ? getComputedStyle(element).animationDuration : null,
    );
  });
  expect(durations).toEqual(["0.1s", "0.1s"]);
  await page.evaluate(() => {
    const states: string[] = [];
    const observer = new MutationObserver(() => {
      const popup = document.querySelector('[data-slot="dialog-content"]');
      states.push(popup?.getAttribute("data-open") !== null && popup !== null ? "open" : "closed");
    });
    observer.observe(document.body, { attributes: true, childList: true, subtree: true });
    (
      window as unknown as { uploadCloseStates: string[]; uploadCloseObserver: MutationObserver }
    ).uploadCloseStates = states;
    (window as unknown as { uploadCloseObserver: MutationObserver }).uploadCloseObserver = observer;
  });
  await page.mouse.click(1100, 460);
  await expect(dialog).not.toBeVisible();
  await expect(page).not.toHaveURL(/upload=invoices/);
  await expect(add).toBeVisible();
  await page.waitForTimeout(250);
  const closeStates = await page.evaluate(() => {
    const state = window as unknown as {
      uploadCloseStates: string[];
      uploadCloseObserver: MutationObserver;
    };
    state.uploadCloseObserver.disconnect();
    return state.uploadCloseStates;
  });
  const firstClosed = closeStates.indexOf("closed");
  expect(firstClosed).toBeGreaterThanOrEqual(0);
  expect(closeStates.slice(firstClosed)).not.toContain("open");

  await add.click();
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.keyboard.press("Escape");
  await expect(dialog).not.toBeVisible();
  await add.click();
  await expect(dialog.getByText("sales.pdf", { exact: true })).toBeVisible();
});

test("history polls processing, retains failed sources and links to review and React register", async ({
  page,
}, testInfo) => {
  await setup(page);
  let processing = true;
  await page.route("**/api/workspace/sales/*/*/uploads", (route) => {
    return route.fulfill({
      json: {
        processing,
        batches: [
          {
            id: "batch-1",
            created_at: "2026-06-15T10:00:00Z",
            review_url: "/gst/1/2026-06/review/sales?batch=batch-1",
            files: [
              {
                id: 1,
                name: "Sales invoices.pdf",
                state: processing ? "processing" : "done",
                label: processing ? "Reading" : "Read",
                invoice_count: processing ? 0 : 8,
                error: null,
                original_url: "/source/file-1",
              },
              {
                id: "file-2",
                name: "Damaged bill.pdf",
                state: "failed",
                label: "Needs attention",
                invoice_count: 0,
                error: "We couldn't read this PDF.",
                original_url: "/source/file-2",
              },
            ],
          },
        ],
      },
    });
  });
  await page.goto("/app/gst/1/2026-06/sales/uploads");
  await expect(page.getByRole("status")).toContainText("reading your PDFs");
  processing = false;
  await expect(page.getByText("8 invoices", { exact: true })).toBeVisible({ timeout: 8000 });
  await expect(page.getByText("We couldn't read this PDF.", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Open source PDF for Damaged bill.pdf (new tab)" }),
  ).toHaveAttribute("href", "/source/file-2");

  await expect(page.getByRole("link", { name: "Open upload" })).toHaveAttribute(
    "href",

    /sales\/uploads\/batch-1$/,
  );
  await page.screenshot({ path: testInfo.outputPath("uploads-desktop.png"), fullPage: true });
  await page.route("**/uploads/batch-1/move", (route) =>
    route.fulfill({
      status: 422,
      json: { error: "These bills have different sellers." },
    }),
  );
  await expect(page.getByRole("button", { name: "Move upload…" })).toHaveCount(0);
  await page.getByRole("button", { name: "Upload actions" }).click();
  await page.getByRole("menuitem", { name: "Move upload…", exact: true }).click();
  const moveDialog = page.getByRole("dialog", { name: "Move upload to another client" });
  await expect(moveDialog).toBeVisible();
  await expect(moveDialog).toContainText("These bills have different sellers.");
  await page.keyboard.press("Escape");
  await expect(moveDialog).not.toBeVisible();
  await expect(page.getByRole("button", { name: "Upload actions" })).toBeFocused();

  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("uploads-narrow.png"), fullPage: true });
  await page.evaluate(() => {
    (window as unknown as { sameDocument: boolean }).sameDocument = true;
  });
  await page.getByRole("link", { name: "View sales register", exact: true }).click();
  await expect(page).toHaveURL(/\/sales\/register$/);
  expect(
    await page.evaluate(() => (window as unknown as { sameDocument: boolean }).sameDocument),
  ).toBe(true);
});

test("history permission failure does not appear as an empty upload list", async ({ page }) => {
  await setup(page);
  await page.route("**/api/workspace/sales/*/*/uploads", (route) =>
    route.fulfill({ status: 403, json: { error: "You cannot access these uploads." } }),
  );
  await page.goto("/app/gst/1/2026-06/sales/uploads");
  await expect(page.getByRole("alert")).toContainText("You cannot access these uploads");
  await expect(page.getByText("No uploads yet", { exact: true })).toHaveCount(0);
});

test("expired storage URL renews the existing token and retries the PDF", async ({ page }) => {
  await setup(page);
  const preparations: unknown[] = [];
  await page.route("**/uploads/prepare", (route) => {
    preparations.push(route.request().postDataJSON());
    return route.fulfill({
      json: {
        token: "existing-token",
        files: [
          {
            name: "sales.pdf",
            url: `http://127.0.0.1:5174/storage/${preparations.length === 1 ? "expired" : "renewed"}`,
          },
        ],
      },
    });
  });
  await page.route("**/storage/*", (route) =>
    route.fulfill({ status: route.request().url().endsWith("expired") ? 403 : 200, body: "" }),
  );
  await page.route("**/api/workspace/sales/*/*/uploads", (route) => {
    if (route.request().method() === "POST") {
      expect(route.request().postDataJSON()).toEqual({ token: "existing-token" });

      return route.fulfill({ json: { ok: true, batch_ref: "batch-1" } });
    }
    return route.fulfill({ json: { batches: [], processing: false } });
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }).click();

  await expect(page).toHaveURL(/\/sales\/uploads\/batch-1$/);

  expect(preparations).toHaveLength(2);
  expect(preparations[1]).toEqual({ token: "existing-token" });
});

test("rejected upload unlocks file replacement before a new preparation", async ({ page }) => {
  await setup(page);
  let prepares = 0;
  let commits = 0;
  await page.route("**/uploads/prepare", (route) => {
    prepares++;
    return route.fulfill({
      json: {
        token: `token-${prepares}`,
        files: [{ name: "sales.pdf", url: "http://127.0.0.1:5174/storage/pdf" }],
      },
    });
  });
  await page.route("**/storage/*", (route) => route.fulfill({ status: 200, body: "" }));
  await page.route("**/api/workspace/sales/*/*/uploads", (route) => {
    if (route.request().method() === "POST") {
      commits++;
      expect(route.request().postDataJSON()).toEqual({ token: `token-${commits}` });
      return route.fulfill(
        commits === 1
          ? { status: 422, json: { error: "Upload expired." } }
          : { json: { ok: true, batch_ref: "batch-1" } },
      );
    }
    return route.fulfill({ json: { batches: [], processing: false } });
  });
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Upload expired.");
  expect(prepares).toBe(1);
  await expect(page.getByRole("button", { name: "Add more", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Remove sales.pdf", exact: true }).click();
  await expect(
    page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }),
  ).toBeDisabled();
  await page.getByLabel("Choose sales PDF files").setInputFiles(pdf("sales.pdf"));
  await page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }).click();

  await expect(page).toHaveURL(/\/sales\/uploads\/batch-1$/);

  expect(prepares).toBe(2);
});

test("view-only role cannot select or upload PDFs", async ({ page }) => {
  await setup(page);
  await page.route("**/api/workspace/sales/*/*", (route) =>
    route.fulfill({ json: { ...workspace(), can_upload: false } }),
  );
  await page.goto("/app/gst/1/2026-06/sales/upload");
  await expect(page.getByRole("status")).toHaveText("Your role allows viewing, not uploading.");
  await expect(page.getByRole("button", { name: "Choose PDFs", exact: true })).toBeDisabled();
  await expect(page.getByLabel("Choose sales PDF files")).toBeDisabled();
  await expect(
    page.getByRole("button", { name: /^Upload (?:\d+ )?PDFs?$/, exact: true }),
  ).toBeDisabled();
  await expect(page.getByRole("link", { name: "View uploads", exact: true })).toBeVisible();
});

test("selection enforces 50 files and keeps upload controls visible above attachments", async ({
  page,
}, info) => {
  await setup(page);
  await page.goto("/app/gst/1/2026-06/sales/upload");
  const transfer = await page.evaluateHandle(() => {
    const data = new DataTransfer();
    data.items.add(
      new File([new Uint8Array(50_000_001)], "too-large.pdf", { type: "application/pdf" }),
    );
    for (let index = 0; index < 51; index++)
      data.items.add(new File(["%PDF"], `sales-${index}.pdf`, { type: "application/pdf" }));
    return data;
  });
  await page
    .getByRole("heading", { name: "Drop your sales PDFs here", exact: true })
    .dispatchEvent("drop", { dataTransfer: transfer });
  await expect(page.getByRole("alert")).toContainText("too-large.pdf: the limit is 50 MB per PDF.");
  await expect(page.getByRole("alert")).toContainText("Choose up to 50 PDFs at a time.");
  await expect(page.getByRole("heading", { name: "50 files selected", exact: true })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Drop your sales PDFs here", exact: true }),
  ).toHaveCount(0);
  const upload = page.getByRole("button", { name: "Upload 50 PDFs", exact: true });
  await expect(upload).toBeInViewport();
  await expect(page.locator('[data-slot="attachment"]')).toHaveCount(50);
  await page
    .getByRole("button", { name: "Remove sales-49.pdf", exact: true })
    .scrollIntoViewIfNeeded();
  await expect(upload).toBeInViewport();
  await page.screenshot({ path: info.outputPath("selected-pdfs-scrolled.png") });
  await page.getByRole("button", { name: "Remove sales-49.pdf", exact: true }).click();
  await expect(page.getByRole("button", { name: "Upload 49 PDFs", exact: true })).toBeInViewport();
  await page
    .getByRole("heading", { name: "49 files selected", exact: true })
    .dispatchEvent("drop", {
      dataTransfer: await page.evaluateHandle(() => {
        const transfer = new DataTransfer();
        transfer.items.add(new File(["%PDF"], "added.pdf", { type: "application/pdf" }));
        return transfer;
      }),
    });
  await expect(page.getByRole("button", { name: "Upload 50 PDFs", exact: true })).toBeInViewport();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: info.outputPath("selected-pdfs.png") });
});

test("remove upload keeps originals and allows individual restore from history", async ({
  page,
}, info) => {
  await setup(page);
  let removed: string[] = [];
  let fail = true;
  const ids = ["one", "two"];
  await page.route("**/api/workspace/sales/*/*/uploads", (route) =>
    route.fulfill({
      json: {
        processing: false,
        batches: [
          {
            id: "38",
            created_at: "2026-06-15T10:00:00Z",
            invoice_ids: ids,
            active_invoice_ids: ids.filter((id) => !removed.includes(id)),
            removed_invoices: removed.map((id) => ({
              id,
              number: id === "one" ? "INV-001" : "INV-002",
            })),
            review_url: "/gst/1/2026-06/sales/register",
            files: [
              {
                id: 38,
                name: "Sales.pdf",
                state: "extracted",
                label: "Read",
                invoice_count: 2,
                original_url: "/source/38",
                error: null,
              },
            ],
          },
        ],
      },
    }),
  );
  await page.route("**/uploads/38/removal", (route) => {
    if (fail) {
      fail = false;
      return route.fulfill({
        status: 409,
        json: { error: "This month is filed. Nothing was removed." },
      });
    }
    const body = route.request().postDataJSON();
    removed =
      body.action === "remove"
        ? body.source_ids
        : removed.filter((id) => !body.source_ids.includes(id));

    return route.fulfill({ json: { ok: true, batch_ref: "batch-1" } });
  });
  await page.goto("/app/gst/1/2026-06/sales/uploads");
  await page.getByRole("button", { name: "Upload actions" }).click();
  await page.getByRole("menuitem", { name: "Remove upload…" }).click();
  const dialog = page.getByRole("alertdialog", { name: "Remove 2 invoices?" });
  await expect(dialog).toContainText("Remove from Breeze Tech’s June 2026 working");
  await page.screenshot({
    path: info.outputPath("remove-upload-confirmation.png"),
    animations: "disabled",
  });
  await dialog.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Nothing was removed");
  await dialog.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.getByRole("button", { name: "2 removed invoices" }).click();
  await expect(page.getByRole("link", { name: /Open source PDF/ })).toBeVisible();
  await page.screenshot({ path: info.outputPath("removed-upload.png") });
  await page.getByRole("button", { name: "Restore invoice INV-001" }).click();
  await page
    .getByRole("alertdialog", { name: "Restore invoice INV-001?" })
    .getByRole("button", { name: "Restore", exact: true })
    .click();
  await expect(page.getByRole("button", { name: "1 removed invoice" })).toBeVisible();
  await page.getByRole("button", { name: "Upload actions" }).click();
  await expect(page.getByRole("menuitem", { name: "Restore removed invoices…" })).toBeVisible();
  await page.screenshot({
    path: info.outputPath("upload-actions-menu.png"),
    animations: "disabled",
  });
  await page.keyboard.press("Escape");
  expect(removed).toEqual(["two"]);
});

test("upload results show partial invoices, retry reading and keep completed reviews available", async ({
  page,
}, info) => {
  await setup(page);

  let state = "failed";

  let calls = 0;

  let release: () => void = () => {};

  const waiting = new Promise<void>((resolve) => {
    release = resolve;
  });

  await page.route("**/api/workspace/sales/1/2026-06/uploads/37", (route) =>
    route.fulfill({
      json: {
        id: "37",
        processing: state === "extracting",
        files: [
          {
            id: 37,
            name: "breeze-2026-05.pdf",
            state,

            completed: state === "extracted" ? 3 : 2,
            total: 3,
            reviewable: 2,
            original_url: "/source/37",

            message:
              "Reading stopped. Completed invoices are saved; retry resumes the remaining read.",

            rows: [
              {
                id: "one",
                number: "25/2026-27",
                buyer: "Vishnu MK",
                pages: [1],
                state: "ready",
                review_url: "/gst/1/2026-06/sales/invoices/one",
              },

              {
                id: "two",
                number: "26/2026-27",
                buyer: "National Traders",
                pages: [2],
                state: "ready",
                review_url: "/gst/1/2026-06/sales/invoices/two",
              },

              {
                id: "three",
                number: "27/2026-27",
                buyer: null,
                pages: [6],
                state:
                  state === "extracted" ? "ready" : state === "extracting" ? "reading" : "failed",
                review_url: state === "extracted" ? "/gst/1/2026-06/sales/invoices/three" : null,
              },
            ],
          },
        ],
      },
    }),
  );

  await page.route("**/uploads/37/retry", async (route) => {
    calls++;

    expect(route.request().postDataJSON()).toEqual({ dump_id: 37 });

    await waiting;

    state = "extracting";

    await route.fulfill({ json: { ok: true } });
  });

  await page.goto("/app/gst/1/2026-06/sales/uploads/37");

  await expect(page.getByRole("status")).toHaveText("2 of 3 invoices read");

  await expect(page.getByRole("row").filter({ hasText: "27/2026-27" })).toContainText(
    "Could not read",
  );

  await expect(page.getByRole("link", { name: "Review", exact: true })).toHaveCount(2);

  await page.screenshot({ path: info.outputPath("partial-upload.png"), fullPage: true });

  await page.getByRole("button", { name: "Retry reading" }).click();

  await expect(page.getByRole("button", { name: "Starting…" })).toBeDisabled();

  expect(calls).toBe(1);

  release();

  await expect(page.getByRole("row").filter({ hasText: "27/2026-27" })).toContainText("Reading…");

  state = "extracted";

  await expect(page.getByRole("status")).toHaveText("3 of 3 invoices read", { timeout: 8000 });

  await expect(page.getByRole("link", { name: "Review", exact: true })).toHaveCount(3);

  await expect(page.getByRole("button", { name: "Retry reading" })).toHaveCount(0);
});
