import fs from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { chromium } from "playwright";

const viewport = {
  width: Number(process.env.SCREENSHOT_VIEWPORT_WIDTH || "1280"),
  height: Number(process.env.SCREENSHOT_VIEWPORT_HEIGHT || "900"),
};

let browser;
let context;
let page;

async function startBrowser() {
  browser = await chromium.connectOverCDP(process.env.CHROME_URL);
  context = browser.contexts()[0] || await browser.newContext({ viewport });
  page = context.pages()[0] || await context.newPage();
  await page.setViewportSize(viewport);
}

async function visit({ url }) {
  await page.goto(url, { waitUntil: "domcontentloaded" });
}

async function screenshot({ path: screenshotPath }) {
  await fs.mkdir(path.dirname(screenshotPath), { recursive: true });
  await page.screenshot({ path: screenshotPath, fullPage: true });
}

async function authenticate({ strategy, login_path: loginPath, fields, credentials }) {
  if (strategy !== "form") {
    throw new Error(`Playwright only supports form auth for screenshots (got ${strategy})`);
  }

  await page.goto(loginPath, { waitUntil: "domcontentloaded" });
  for (const [field, selector] of Object.entries(fields)) {
    if (field === "submit") continue;
    await page.locator(selector).fill(credentials[field] || "");
  }
  await page.locator(fields.submit).click();
  await page.waitForLoadState("networkidle");
}

async function waitForLoad() {
  await page.waitForLoadState("networkidle");
}

async function currentPath() {
  return new URL(page.url()).pathname;
}

async function quit() {
  await page?.close();
  await browser?.close();
}

const handlers = {
  start_browser: startBrowser,
  visit,
  screenshot,
  authenticate,
  wait_for_load: waitForLoad,
  current_path: currentPath,
  quit,
};

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

for await (const line of rl) {
  const message = JSON.parse(line);
  const handler = handlers[message.command];

  try {
    if (!handler) {
      throw new Error(`Unsupported command: ${message.command}`);
    }

    const result = await handler(message);
    process.stdout.write(`${JSON.stringify({ ok: true, current_path: result })}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ ok: false, error: error.message })}\n`);
  }
}
