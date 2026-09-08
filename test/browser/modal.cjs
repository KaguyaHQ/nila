// Run against a local Nila dev server with Playwright available on NODE_PATH:
// NILA_BASE_URL=http://localhost:4010 node test/browser/modal.cjs
const assert = require("node:assert/strict")
const {chromium} = require("playwright")

const baseURL = process.env.NILA_BASE_URL || "http://localhost:4000"
const push = (page, event, value = {}) => page.evaluate(({event, value}) => new Promise(resolve => {
  const el = document.querySelector("[data-phx-main]")
  window.liveSocket.main.pushEvent("click", el, el, event, value, {}, resolve)
}), {event, value})

async function check(browser, options, name) {
  const context = await browser.newContext(options)
  const page = await context.newPage()
  page.setDefaultTimeout(10000)
  const errors = []
  page.on("pageerror", error => errors.push(error.message))
  await page.goto(`${baseURL}/dev/design-system`)
  await page.locator("[data-phx-main].phx-connected").waitFor()

  // A pre-existing top-layer background popover must not beat the modal.
  await page.evaluate(() => {
    const popover = document.createElement("div")
    popover.id = "background-popover"
    popover.setAttribute("popover", "manual")
    popover.innerHTML = '<button id="background-action">Background</button>'
    document.body.append(popover)
    popover.showPopover()
    const chrome = document.createElement("button")
    chrome.id = "high-chrome"
    chrome.textContent = "Background chrome"
    chrome.style.cssText = "position:fixed;inset:0;z-index:2147483647"
    document.body.append(chrome)
  })
  await push(page, "open-design-sheet")
  await page.locator("#ds-sheet:modal").waitFor()
  assert.equal(await page.evaluate(() => document.elementFromPoint(10, 10).closest("dialog")?.id), "ds-sheet")
  await page.evaluate(() => document.querySelector("#background-action").focus())
  assert.notEqual(await page.evaluate(() => document.activeElement.id), "background-action")
  await page.evaluate(() => {
    document.querySelector("#background-popover").remove()
    document.querySelector("#high-chrome").remove()
  })

  await page.locator("#ds-sheet-open-modal").click()
  await page.locator("#ds-modal:modal").waitFor()
  assert.equal(await page.locator("dialog:modal").count(), 2)
  for (let i = 0; i < 12; i++) {
    await page.keyboard.press(i < 6 ? "Tab" : "Shift+Tab")
    // Native dialogs may let Tab visit browser chrome (activeElement=body),
    // but must never focus a control in the underlying sheet or page.
    assert.equal(await page.evaluate(() => document.activeElement === document.body ||
      document.activeElement.closest("dialog")?.id === "ds-modal"), true)
  }

  // Real shared menu: Escape and outside click dismiss only the menu.
  await page.locator("#ds-modal-menu-trigger").click()
  await page.locator("#ds-modal-menu-popover:popover-open").waitFor()
  await page.keyboard.press("Escape")
  await page.locator("#ds-modal-menu-popover:popover-open").waitFor({state: "hidden"})
  assert.equal(await page.locator("dialog:modal").count(), 2)
  assert.equal(await page.evaluate(() => document.activeElement.id), "ds-modal-menu-trigger")
  await page.locator("#ds-modal-menu-trigger").click()
  await page.locator("#ds-modal-title").click()
  assert.equal(await page.locator("dialog:modal").count(), 2)
  assert.equal(await page.locator(":popover-open").count(), 0)

  // Unrelated LiveView patch must preserve native open state and focus.
  await page.locator("#ds-modal-confirm").focus()
  await push(page, "set-review-scope", {scope: "all"})
  assert.equal(await page.locator("dialog:modal").count(), 2)
  assert.equal(await page.evaluate(() => document.activeElement.id), "ds-modal-confirm")

  const scrollState = () => page.evaluate(() => [...document.querySelectorAll("*")]
    .filter(el => !el.closest("dialog") && el.scrollHeight > el.clientHeight)
    .map(el => el.scrollTop))
  const beforeScroll = await scrollState()
  await page.mouse.move(12, 12)
  await page.mouse.wheel(0, 800)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  assert.deepEqual(await scrollState(), beforeScroll)
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY), "hidden")

  if (options.hasTouch) {
    const cdp = await context.newCDPSession(page)
    await cdp.send("Input.dispatchTouchEvent", {type: "touchStart", touchPoints: [{x: 12, y: 600}]})
    for (const y of [500, 400, 300, 200]) {
      await cdp.send("Input.dispatchTouchEvent", {type: "touchMove", touchPoints: [{x: 12, y}]})
    }
    await cdp.send("Input.dispatchTouchEvent", {type: "touchEnd", touchPoints: []})
    assert.deepEqual(await scrollState(), beforeScroll)
    await cdp.detach()
  }

  // The actual evidence reader is a DOM child of the modal. Its own page
  // navigation patches must not dismiss it or operate the parent review.
  await page.locator("#ds-modal-open-reader").click()
  await page.locator("#ds-reader:modal").waitFor()
  assert.equal(await page.locator("dialog:modal").count(), 3)
  const firstImage = await page.locator("#ds-reader-stage img").getAttribute("src")
  await page.keyboard.press("ArrowRight")
  await page.waitForFunction(src => document.querySelector("#ds-reader-stage img").getAttribute("src") !== src, firstImage)
  assert.equal(await page.locator("#ds-reader:modal").count(), 1)
  await page.keyboard.press("Escape")
  await page.locator("#ds-reader").waitFor({state: "detached"})
  assert.equal(await page.evaluate(() => document.activeElement.id), "ds-modal-open-reader")
  assert.equal(await page.locator("dialog:modal").count(), 2)

  // Only the top dialog closes, then focus returns into the still-modal sheet.
  await page.keyboard.press("Escape")
  await page.locator("#ds-modal").waitFor({state: "detached"})
  assert.equal(await page.locator("#ds-sheet:modal").count(), 1)
  assert.equal(await page.evaluate(() => document.activeElement.id), "ds-sheet-open-modal")
  assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY), "hidden")
  await page.keyboard.press("Escape")
  await page.locator("#ds-sheet").waitFor({state: "detached"})
  assert.equal(await page.evaluate(() => document.activeElement.id), "ds-open-sheet")
  assert.notEqual(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY), "hidden")

  // Escape policy changes are read on demand; keep modality while awaiting server removal.
  await page.locator("#ds-open-modal").click()
  await page.locator("#ds-modal:modal").waitFor()
  await page.evaluate(() => document.querySelector("#ds-modal").dataset.closeOnEscape = "false")
  // Exercise the keydown fallback too: the fixture still has closerequest,
  // rather than relying on closedby=none to enforce the disabled policy.
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press("Escape")
    assert.equal(await page.locator("#ds-modal:modal").count(), 1)
  }
  // Exercise reconciliation if a platform still forces a non-cancelable close.
  await page.evaluate(() => {
    const dialog = document.querySelector("#ds-modal")
    dialog.dispatchEvent(new Event("cancel", {cancelable: false}))
    dialog.close()
  })
  await page.locator("#ds-modal:modal").waitFor()
  await page.evaluate(() => document.querySelector("#ds-modal").dataset.variant = "workbench")
  await page.mouse.click(12, 12)
  assert.equal(await page.locator("#ds-modal:modal").count(), 1)
  await page.evaluate(() => document.querySelector("#ds-modal").dataset.variant = "modal")
  await page.evaluate(() => document.querySelector("#ds-modal").dataset.closeOnEscape = "true")
  await page.mouse.click(12, 12)
  await page.locator("#ds-modal").waitFor({state: "detached"})

  // A native close must reconcile server state, not leave a hidden mounted modal.
  await page.locator("#ds-open-modal").click()
  await page.locator("#ds-modal:modal").waitFor()
  await page.evaluate(() => document.querySelector("#ds-modal").close())
  await page.locator("#ds-modal").waitFor({state: "detached"})

  // Repeated permitted Escape must keep the page inert until LiveView responds.
  await page.locator("#ds-open-modal").click()
  await page.locator("#ds-modal:modal").waitFor()
  await page.evaluate(() => window.liveSocket.enableLatencySim(1000))
  for (let i = 0; i < 6; i++) {
    await page.keyboard.press("Escape")
    assert.equal(await page.locator("#ds-modal:modal").count(), 1)
    assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY), "hidden")
  }
  await page.locator("#ds-modal").waitFor({state: "detached"})
  await page.evaluate(() => window.liveSocket.disableLatencySim())

  // Removing the lower dialog first must not steal focus or release modality.
  await page.locator("#ds-open-sheet").click()
  await page.locator("#ds-sheet-open-modal").click()
  await page.locator("#ds-modal:modal").waitFor()
  await page.locator("#ds-modal-menu-trigger").click()
  await page.locator("#ds-modal-menu-popover:popover-open").waitFor()
  await page.evaluate(() => document.querySelector("#ds-sheet").close())
  await page.locator("#ds-sheet").waitFor({state: "detached"})
  assert.equal(await page.locator("#ds-modal:modal").count(), 1)
  assert.equal(await page.evaluate(() => document.activeElement.closest("dialog")?.id), "ds-modal")
  await page.locator("#ds-modal-menu-popover:popover-open").waitFor()
  await page.locator("#ds-modal-menu-confirm").click()
  await page.locator("#ds-modal").waitFor({state: "detached"})
  assert.equal(await page.locator(":popover-open").count(), 0)
  assert.equal(await page.evaluate(() => document.activeElement.id), "ds-open-sheet")
  assert.notEqual(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY), "hidden")
  assert.deepEqual(errors, [])
  console.log(`${name}: modal layering, inertness, focus, scrolling, menu, stacking and LiveView patches passed`)
  await context.close()
}

;(async () => {
  const browser = await chromium.launch({headless: true})
  try {
    await check(browser, {viewport: {width: 1440, height: 1000}}, "desktop Chromium")
    await check(browser, {viewport: {width: 390, height: 844}, isMobile: true, hasTouch: true}, "mobile Chromium emulation")
  } finally {
    await browser.close()
  }
})().catch(error => { console.error(error); process.exitCode = 1 })
