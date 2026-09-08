// NILA_BASE_URL=http://localhost:4010 node test/browser/action_menu.cjs
const assert = require("node:assert/strict")
const {chromium} = require("playwright")

;(async () => {
  const browser = await chromium.launch({headless: true})
  try {
    const page = await browser.newPage({viewport: {width: 1280, height: 800}})
    const errors = []
    page.on("pageerror", error => errors.push(error.message))
    await page.goto(`${process.env.NILA_BASE_URL || "http://localhost:4010"}/dev/design-system`)
    await page.locator("[data-phx-main].phx-connected").waitFor()
    await page.locator("#ds-open-modal").click()
    await page.locator("#ds-modal:modal").waitFor()
    const trigger = page.locator("#ds-modal-menu-trigger")
    const menu = page.locator("#ds-modal-menu-popover")
    await trigger.focus()
    await page.keyboard.press("ArrowDown")
    await menu.waitFor({state: "visible"})
    await page.waitForFunction(() => document.activeElement.id === "ds-modal-menu-confirm")

    const bounds = () => menu.evaluate(el => {
      const r = el.getBoundingClientRect()
      return {x: r.x, y: r.y, right: r.right, bottom: r.bottom,
        width: innerWidth, height: innerHeight, scroll: el.scrollHeight > el.clientHeight}
    })
    const onscreen = async () => {
      const r = await bounds()
      assert.ok(r.x >= 0 && r.y >= 0 && r.right <= r.width && r.bottom <= r.height, JSON.stringify(r))
    }
    await onscreen()
    const before = await bounds()
    await page.locator("#ds-modal-menu").evaluate(el => el.style.transform = "translateY(40px)")
    assert.equal(Math.round((await bounds()).y - before.y), 40)

    // Real LiveView patch while the menu is open: no inline position to lose.
    await page.evaluate(() => new Promise(resolve => {
      const el = document.querySelector("[data-phx-main]")
      window.liveSocket.main.pushEvent("click", el, el, "set-review-scope", {scope: "all"}, {}, resolve)
    }))
    await menu.waitFor({state: "visible"})
    await onscreen()

    const wrapper = page.locator("#ds-modal-menu")
    for (const corner of ["top:8px;left:8px", "top:8px;right:8px",
      "bottom:8px;left:8px", "bottom:8px;right:8px"]) {
      await wrapper.evaluate((el, corner) => el.style.cssText = `position:fixed;${corner}`, corner)
      await onscreen()
      if (corner.startsWith("bottom")) {
        assert.ok((await bounds()).bottom <= (await trigger.boundingBox()).y)
      }
    }
    await wrapper.evaluate(el => el.removeAttribute("style"))

    // Constrain a long label and a tall list in a short desktop window.
    await page.setViewportSize({width: 1024, height: 480})
    await menu.evaluate(el => {
      el.querySelector("button span").textContent = "Download the complete reconciliation statement ".repeat(8)
    })
    await onscreen()
    await menu.evaluate(el => {
      const item = el.querySelector("button")
      item.querySelector("span").textContent = "Review invoice"
      for (let i = 0; i < 20; i++) {
        const clone = item.cloneNode(true)
        clone.id = `audit-action-${i}`
        clone.removeAttribute("phx-click")
        el.append(clone)
      }
    })
    await onscreen()
    assert.equal((await bounds()).scroll, true)
    await page.keyboard.press("End")
    assert.equal(await page.evaluate(() => document.activeElement.id), "audit-action-19")
    await page.keyboard.press("Home")
    assert.equal(await page.evaluate(() => document.activeElement.id), "ds-modal-menu-confirm")

    // A 1280x800 desktop at 200% zoom has this much CSS viewport space.
    // This checks the reduced space, not browser-toolbar zoom itself.
    await page.setViewportSize({width: 640, height: 400})
    await onscreen()
    await page.keyboard.press("Escape")
    await menu.waitFor({state: "hidden"})
    assert.equal(await page.locator("#ds-modal:modal").count(), 1)
    assert.equal(await page.evaluate(() => document.activeElement.id), "ds-modal-menu-trigger")
    assert.deepEqual(errors, [])
    console.log("Chromium action menu: anchoring, layout movement, LiveView patch, overflow, reduced viewport and keyboard passed")
  } finally {
    await browser.close()
  }
})().catch(error => { console.error(error); process.exitCode = 1 })
