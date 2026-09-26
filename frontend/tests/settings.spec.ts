import { mockNavigation } from "./fixtures/navigation";
import { expect, test, type Page } from "@playwright/test";
import type { SettingsData } from "../src/lib/settings-api";

function fixture(manage = true): SettingsData {
  return {
    user: {
      id: 1,
      name: "Vasanth",
      email: "vasanth@example.test",
      org: "Nila Dev CA",
      role: manage ? "Owner" : "Viewer",
    },
    firm: { name: "Nila Dev CA", contact_phone: null },
    can_manage_firm: manage,
    can_manage_users: manage,
    demo_reset: null,
    clients: [],
    roles: [
      { label: "Owner", value: "owner" },
      { label: "Operator", value: "member" },
      { label: "Viewer", value: "viewer" },
    ],
    members: manage
      ? [
          {
            id: 1,
            name: "Vasanth",
            email: "vasanth@example.test",
            role: "owner",
            active: true,
            invited: false,
            self: true,
            can_change_role: false,
            can_toggle_active: false,
          },
          {
            id: 2,
            name: "Anita",
            email: "anita@example.test",
            role: "viewer",
            active: true,
            invited: true,
            self: false,
            can_change_role: true,
            can_toggle_active: true,
          },
        ]
      : [],
  };
}

test("demo reset names the whole firm and reports server refusal", async ({ page }, testInfo) => {
  const data = await setup(page);
  data.demo_reset = { id: 2, name: "Demo Firm" };
  let resets = 0;
  await page.route("**/api/workspace/settings/demo-reset", (route) => {
    resets++;
    expect(route.request().headers()["x-csrf-token"]).toBe("settings-csrf");
    return route.fulfill(
      resets === 1
        ? { status: 409, json: { error: "Invoices are still processing." } }
        : { json: { message: "Demo reset. Your firm is ready for new clients." } },
    );
  });
  await page.goto("/app/settings/workspace");
  await page.locator("#main-content").getByRole("button", { name: "Reset demo" }).click();
  await expect(page.getByText(/every client and their work across all months/)).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("demo-reset-confirmation.png"), fullPage: true });
  await page.getByRole("button", { name: "Cancel" }).click();
  expect(resets).toBe(0);
  await page.locator("#main-content").getByRole("button", { name: "Reset demo" }).click();
  await page.getByRole("button", { name: "Reset demo" }).last().click();
  await expect(page.getByRole("alert")).toHaveText("Invoices are still processing.");
  expect(resets).toBe(1);
  await page.getByRole("button", { name: "Reset demo" }).last().click();
  await expect(page.getByText("Demo reset. Your firm is ready for new clients.")).toBeVisible();
  expect(resets).toBe(2);
});
async function setup(page: Page, manage = true) {
  await mockNavigation(page);
  const data = fixture(manage);
  await page.route("**/api/workspace/settings", (route) => route.fulfill({ json: data }));
  await page.addInitScript(() =>
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = "settings-csrf";
      document.head.append(meta);
    }),
  );
  return data;
}

test("profile uses React navigation, serif wordmark and saves only after server confirmation", async ({
  page,
}, testInfo) => {
  const data = await setup(page);
  let writes = 0;
  let release!: () => void;
  const pending = new Promise<void>((resolve) => (release = resolve));
  await page.route("**/api/workspace/settings/name", async (route) => {
    writes++;
    expect(route.request().headers()["x-csrf-token"]).toBe("settings-csrf");
    expect(route.request().postDataJSON()).toEqual({ name: "New name" });
    await pending;
    data.user.name = "New name";
    await route.fulfill({ json: { message: "Name updated." } });
  });
  await page.goto("/app/settings/profile");
  await expect(page.getByRole("heading", { name: "Settings", exact: true })).toBeVisible();
  await expect(page.getByLabel("Nila clients home")).toHaveText("nila");
  await expect(page.getByLabel("Nila clients home")).toHaveCSS("font-family", /Newsreader/);
  await page.screenshot({ path: testInfo.outputPath("settings-profile.png"), fullPage: true });
  await page.getByLabel("Name", { exact: true }).fill("New name");
  await page.getByRole("button", { name: "Save name" }).dblclick();
  await expect(page.getByRole("button", { name: "Saving…" })).toBeDisabled();
  expect(writes).toBe(1);
  release();
  await expect(page.locator('[data-slot="toast-title"]')).toHaveText("Name updated.");
  await expect(page.getByRole("heading", { name: "New name", exact: true })).toBeVisible();
  await page.evaluate(() => {
    document.body.dataset.retained = "yes";
  });
  await page
    .getByRole("navigation", { name: "Settings" })
    .getByRole("link", { name: "Security", exact: true })
    .click();
  await expect(page.locator("body")).toHaveAttribute("data-retained", "yes");
  await expect(page.getByLabel("New password", { exact: true })).toBeVisible();
});

test("validation retains input and email remains unchanged until confirmed", async ({ page }) => {
  await setup(page);
  let succeeds = false;
  await page.route("**/api/workspace/settings/email", (route) =>
    route.fulfill(
      succeeds
        ? { json: { message: "A confirmation link has been sent." } }
        : {
            status: 422,
            json: {
              error: "Check the highlighted fields.",
              fields: { current_password: ["is not valid"] },
            },
          },
    ),
  );
  await page.goto("/app/settings/profile");
  await page.getByLabel("New email").fill("new@example.test");
  await page.getByLabel("Current password").fill("wrong");
  await page.getByRole("button", { name: "Send confirmation link" }).click();
  await expect(page.getByRole("alert")).toHaveText("Check the highlighted fields.");
  await expect(page.getByLabel("New email")).toHaveValue("new@example.test");
  await expect(page.getByLabel("Current password")).toHaveAttribute("aria-invalid", "true");
  succeeds = true;
  await page.getByLabel("Current password").fill("correct-password");
  await page.getByRole("button", { name: "Send confirmation link" }).click();
  await expect(page.locator('[data-slot="toast-title"]')).toHaveText(
    "A confirmation link has been sent.",
  );
  await expect(page.getByText("vasanth@example.test", { exact: true })).toBeVisible();
});

test("viewer cannot open firm or users controls", async ({ page }) => {
  await setup(page, false);
  await page.goto("/app/settings/profile");
  const nav = page.getByRole("navigation", { name: "Settings" });
  await expect(nav.getByRole("link", { name: "Firm", exact: true })).toHaveCount(0);
  await expect(nav.getByRole("link", { name: "Users", exact: true })).toHaveCount(0);
  await page.goto("/app/settings/users");
  await expect(page.getByRole("alert")).toHaveText("You don't have access to this settings page.");
  await expect(page.getByRole("button", { name: "Invite user" })).toHaveCount(0);
});

test("firm saves and member errors never pretend a role changed", async ({ page }, testInfo) => {
  await setup(page);
  await page.route("**/api/workspace/settings/firm", (route) =>
    route.fulfill({ json: { message: "Firm details saved." } }),
  );
  await page.goto("/app/settings/workspace");
  await page.getByLabel("Firm name").fill("New firm");
  await page.getByRole("button", { name: "Save changes" }).click();
  await expect(page.locator('[data-slot="toast-title"]')).toHaveText("Firm details saved.");
  await page
    .getByRole("navigation", { name: "Settings" })
    .getByRole("link", { name: "Users", exact: true })
    .click();
  await expect(page.getByLabel("Role for Vasanth")).toBeDisabled();
  await page.route("**/api/workspace/settings/members/2", (route) =>
    route.fulfill({ status: 422, json: { error: "Could not update the role." } }),
  );
  await page.getByLabel("Role for Anita").selectOption("member");
  await expect(page.getByRole("alert")).toHaveText("Could not update the role.");
  await expect(page.getByLabel("Role for Anita")).toHaveValue("viewer");
  await page.getByRole("button", { name: "Invite user", exact: true }).click();
  await page.screenshot({ path: testInfo.outputPath("settings-users.png"), fullPage: true });
  await page.route("**/api/workspace/settings/invitations", (route) => {
    expect(route.request().postDataJSON()).toEqual({
      name: "Staff",
      email: "staff@example.test",
      role: "member",
    });
    return route.fulfill({ json: { message: "Invitation sent." } });
  });
  await page.getByLabel("Name", { exact: true }).fill("Staff");
  await page.getByLabel("Work email").fill("staff@example.test");
  await page.getByRole("button", { name: "Send invitation" }).click();
  await expect(page.getByText("Invitation sent.", { exact: true })).toBeVisible();
});

test("password success reloads the renewed session and sign out needs confirmation", async ({
  page,
}, testInfo) => {
  await setup(page);
  await page.route("**/api/workspace/settings/password", (route) =>
    route.fulfill({
      json: {
        message: "Password updated.",
        redirect_to: "/app/settings/security?updated=password",
      },
    }),
  );
  await page.goto("/app/settings/security");
  await page.getByLabel("Current password", { exact: true }).fill("oldpassword123");
  await page.getByLabel("New password", { exact: true }).fill("newpassword123");
  await page.getByLabel("Confirm new password").fill("newpassword123");
  await page.getByRole("button", { name: "Update password" }).click();
  await expect(page).toHaveURL(/updated=password$/);
  await expect(page.getByRole("status")).toHaveText("Password updated.");
  let calls = 0;
  await page.route("**/api/workspace/settings/sessions", (route) => {
    calls++;
    return route.fulfill({ json: { message: "Signed out.", redirect_to: "/users/log_in" } });
  });
  await page.route("**/users/log_in", (route) =>
    route.fulfill({ contentType: "text/html", body: "Sign in" }),
  );
  await page.getByRole("button", { name: "Sign out everywhere", exact: true }).click();
  expect(calls).toBe(0);
  await expect(page.getByRole("alertdialog").getByRole("button", { name: "Cancel" })).toBeFocused();
  await page.mouse.click(10, 10);
  await expect(page.getByRole("alertdialog")).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath("signout-confirmation.png") });
  await page.getByRole("alertdialog").getByRole("button", { name: "Cancel" }).click();
  await expect(page.getByRole("alertdialog")).toBeHidden();
  expect(calls).toBe(0);
  await page.getByRole("button", { name: "Sign out everywhere", exact: true }).click();
  await page
    .getByRole("alertdialog")
    .getByRole("button", { name: "Sign out everywhere", exact: true })
    .click();
  await expect(page).toHaveURL(/\/users\/log_in$/);
  expect(calls).toBe(1);
});

test("unauthenticated settings does not render account data", async ({ page }) => {
  await page.route("**/api/workspace/settings", (route) =>
    route.fulfill({ status: 401, json: { error: "Sign in to continue." } }),
  );
  await page.goto("/app/settings/profile");
  await expect(page.getByRole("link", { name: "Sign in", exact: true })).toBeVisible();
  await expect(page.getByLabel("Name", { exact: true })).toHaveCount(0);
});
