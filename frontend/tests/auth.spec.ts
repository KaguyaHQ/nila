import { expect, test, type Page } from "@playwright/test";
import type { AuthPageData } from "../src/pages/auth";

test("logout confirmation appears once and can be dismissed", async ({ page }) => {
  await auth(page, { info: "Signed out." });
  const toast = page.locator('[data-slot="toast"]');
  await expect(toast).toHaveCount(1);
  await expect(toast).toContainText("Signed out.");
  await expect(page.getByRole("heading", { name: "Sign in to Nila" })).toBeVisible();
  await toast.locator('[data-slot="toast-close"]').click();
  await expect(toast).toHaveCount(0);
});
async function auth(page: Page, data: Partial<AuthPageData> = {}) {
  const boot = { kind: "login", action: "/users/log_in", users: [], errors: {}, ...data };
  await page.route("**/users/**", async (route) => {
    if (route.request().method() !== "GET")
      return route.fulfill({ contentType: "text/html", body: "Submitted to Phoenix" });
    const response = await route.fetch();
    await route.fulfill({
      response,
      body: (await response.text()).replace(
        "</head>",
        `<meta name="csrf-token" content="test-csrf"><script id="auth-page" type="application/json">${JSON.stringify(boot).replaceAll("<", "\\u003c")}</script></head>`,
      ),
    });
  });
  await page.goto(boot.action);
}
test("login posts credentials and CSRF to Phoenix", async ({ page }, info) => {
  await auth(page);
  await expect(page.getByRole("heading", { name: "Sign in to Nila" })).toBeVisible();
  await expect(page.getByRole("complementary")).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Arrange a test" })).toHaveAttribute(
    "href",
    "/contact",
  );
  await page.getByLabel("Work email").fill("ca@example.com");
  await page.getByLabel("Password", { exact: true }).fill("a-password");
  await page.getByRole("button", { name: "Show password", exact: true }).click();
  await expect(page.getByLabel("Password", { exact: true })).toHaveAttribute("type", "text");
  await page.getByRole("button", { name: "Hide password", exact: true }).click();
  await page.getByRole("checkbox", { name: "Keep me signed in" }).check();
  await page.screenshot({ path: info.outputPath("login.png"), fullPage: true });
  const sent = page.waitForRequest((r) => r.method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect(Object.fromEntries(new URLSearchParams((await sent).postData()!))).toEqual({
    _csrf_token: "test-csrf",
    "user[email]": "ca@example.com",
    "user[password]": "a-password",
    "user[remember_me]": "true",
  });
});
test("invalid credentials retain email but never password", async ({ page }) => {
  await auth(page, { email: "ca@example.com", error: "Invalid email or password." });
  await expect(page.getByRole("alert")).toHaveText("Invalid email or password.");
  await expect(page.getByLabel("Work email")).toHaveValue("ca@example.com");
  await expect(page.getByLabel("Password", { exact: true })).toHaveValue("");
});
test("reset field errors remain usable", async ({ page }, info) => {
  await auth(page, {
    kind: "reset",
    action: "/users/reset_password/token",
    valid: true,
    errors: { password_confirmation: ["does not match password"] },
  });
  await expect(page.getByRole("alert")).toHaveText("does not match password");
  await expect(page.getByLabel("Confirm password", { exact: true })).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.getByLabel("New password", { exact: true })).toHaveAttribute("minlength", "8");
  await page.screenshot({ path: info.outputPath("reset-errors.png"), fullPage: true });
});
for (const kind of ["reset", "invite"] as const) {
  test(`${kind} expired links never display password controls`, async ({ page }) => {
    await auth(page, {
      kind,
      action: `/users/${kind === "reset" ? "reset_password" : "invite"}/expired`,
      valid: false,
    });
    await expect(page.getByRole("heading", { name: /no longer valid/ })).toBeVisible();
    await expect(page.locator('input[type="password"]')).toHaveCount(0);
  });
}
test("invitation accepts the eight-character password minimum", async ({ page }, info) => {
  await auth(page, {
    kind: "invite",
    action: "/users/invite/token",
    valid: true,
    email: "client@example.com",
  });
  await page.getByLabel("New password", { exact: true }).fill("eight123");
  await page.getByLabel("Confirm password", { exact: true }).fill("eight123");
  await page.screenshot({ path: info.outputPath("invite.png"), fullPage: true });
  const sent = page.waitForRequest((r) => r.method() === "POST");
  await page.getByRole("button", { name: "Set password and sign in" }).click();
  expect((await sent).url()).toContain("/users/invite/token");
});
test("verification provides resend and Phoenix logout", async ({ page }) => {
  await auth(page, {
    kind: "confirmation",
    action: "/users/confirm",
    email: "ca@example.com",
    confirmed: false,
  });
  await expect(page.getByRole("button", { name: "Resend verification email" })).toBeVisible();
  const sent = page.waitForRequest((r) => r.method() === "POST");
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  const body = new URLSearchParams((await sent).postData()!);
  expect(body.get("_method")).toBe("delete");
  expect(body.get("_csrf_token")).toBe("test-csrf");
});

test("development shortcuts name the workspaces and submit the matching identity", async ({ page }, info) => {
  await auth(page, { users: [
    { name: "Firm workspace", email: "firm@nila.test" },
    { name: "Business workspace", email: "business@nila.test" },
  ] });
  await expect(page.getByRole("button", { name: "Firm workspace", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Business workspace", exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("workspace-logins.png"), fullPage: true });
  const sent = page.waitForRequest((request) => request.method() === "POST");
  await page.getByRole("button", { name: "Business workspace", exact: true }).click();
  expect(Object.fromEntries(new URLSearchParams((await sent).postData()!))).toEqual({
    _csrf_token: "test-csrf", dev_login: "true", email: "business@nila.test",
  });
});
