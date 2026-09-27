import type { Locator } from "@playwright/test";

export async function chooseSelect(trigger: Locator, value: string) {
  const escaped = value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  await trigger.click();
  await trigger.page().locator(`[role="option"][data-value="${escaped}"]`).click();
}
