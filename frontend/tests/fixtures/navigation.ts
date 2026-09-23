import type { Page } from "@playwright/test";
import type { components } from "../../src/lib/generated/workspace";
export async function mockNavigation(page: Page) {
  let workspace: components["schemas"]["WorkspaceNavigation"] | null = null;
  await page.context().route("**/api/workspace/navigation", (route) => {
    if (route.request().method() === "PUT") workspace = route.request().postDataJSON();
    return route.fulfill({ json: { workspace } });
  });
}
