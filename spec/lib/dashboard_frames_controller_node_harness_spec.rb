# frozen_string_literal: true

require "open3"
require "rails_helper"

# Node regression harness for the dashboard-frames stale-while-revalidate
# cache, following the ThemeControllerNodeHarness pattern.
#
# @spec DASHBOARD-FRAME-CACHE-001 002 003 004 005 006 007
# See docs/intent/dashboard-frame-caching/dashboard-frame-caching-specs.md.
class DashboardFramesControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/dashboard_frames_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class DashboardFramesController extends Controller {");

    const DashboardFramesController = new Function(transformed)();

    function assert(condition, message) {
      if (!condition) throw new Error(message);
    }

    function buildFrame(id, src, { html = '<div class="skeleton"></div>' } = {}) {
      const frame = {
        id,
        dataset: { dashboardFramesSrc: src },
        innerHTML: html,
        listeners: {},
        classes: new Set(),
        attributes: {}
      };
      frame.classList = {
        add: (...names) => names.forEach((n) => frame.classes.add(n)),
        remove: (...names) => names.forEach((n) => frame.classes.delete(n)),
        contains: (name) => frame.classes.has(name)
      };
      frame.getAttribute = (name) => frame.attributes[name] ?? null;
      frame.setAttribute = (name, value) => { frame.attributes[name] = value; };
      frame.addEventListener = (type, fn) => {
        (frame.listeners[type] = frame.listeners[type] || []).push(fn);
      };
      frame.removeEventListener = (type, fn) => {
        frame.listeners[type] = (frame.listeners[type] || []).filter((f) => f !== fn);
      };
      // Dispatches an event; returns true when default was prevented.
      frame.dispatch = (type) => {
        let prevented = false;
        (frame.listeners[type] || []).forEach((fn) => fn({
          target: frame,
          type,
          preventDefault: () => { prevented = true; }
        }));
        return prevented;
      };
      return frame;
    }

    function buildStorage(initial = {}, { throwOn = null } = {}) {
      return {
        store: { ...initial },
        getItem(key) {
          if (throwOn === "getItem") throw new Error("storage blocked");
          return this.store[key] ?? null;
        },
        setItem(key, value) {
          if (throwOn === "setItem") throw new Error("quota exceeded");
          this.store[key] = value;
        }
      };
    }

    function connectController({ frames, storage, scope = "1:9" }) {
      let timer = null;
      global.window = {
        setTimeout(fn) { timer = fn; return 1; },
        clearTimeout() {},
        sessionStorage: storage
      };

      const controller = Object.create(DashboardFramesController.prototype);
      controller.frameTargets = frames;
      controller.cacheScopeValue = scope;
      controller.frameDelayValue = 0;
      controller.initialDelayValue = 0;
      controller.connect();

      return {
        controller,
        runTimer() {
          assert(timer, "expected a pending stagger timer");
          const fn = timer;
          timer = null;
          fn();
        }
      };
    }

    const METRICS_SRC = "/dashboard/metrics?time_range=cumulative";
    const QUEUE_SRC = "/dashboard/queue_health";
    const metricsKey = (scope) => `dashboard-frame:v1:${scope}:dashboard-metrics:${METRICS_SRC}`;

    // 001 + 002 + 005: cache hit hydrates instantly and dims; a different
    // user's entry (same frame, same src) must not hydrate.
    const storage = buildStorage({ [metricsKey("1:9")]: "<div>cached metrics</div>" });
    const mine = buildFrame("dashboard-metrics", METRICS_SRC);
    connectController({ frames: [mine], storage, scope: "1:9" });
    assert(mine.innerHTML === "<div>cached metrics</div>", "cache hit should hydrate immediately");
    assert(mine.classList.contains("opacity-60"), "hydrated frame should be dimmed");
    assert(mine.getAttribute("src") === null, "hydration must not trigger a load");
    const otherUser = buildFrame("dashboard-metrics", METRICS_SRC);
    connectController({ frames: [otherUser], storage, scope: "1:8" });
    assert(otherUser.innerHTML.includes("skeleton"), "another user's cache entry must not hydrate");

    // 002 + 003: stagger revalidates, frame-load undims and refreshes the entry.
    const revalidate = connectController({ frames: [mine], storage, scope: "1:9" });
    revalidate.runTimer();
    assert(mine.getAttribute("src") === METRICS_SRC, "stagger should load the deferred src");
    mine.innerHTML = "<div>fresh metrics</div>";
    assert(mine.dispatch("turbo:frame-load") === false, "frame-load should not need preventDefault");
    assert(!mine.classList.contains("opacity-60"), "fresh content should undim");
    assert(storage.store[metricsKey("1:9")] === "<div>fresh metrics</div>", "frame-load should refresh the cache");

    // 003: in-frame navigation (frame URL changed) must not poison the cache.
    const navFrame = buildFrame("dashboard-metrics", METRICS_SRC);
    const navRun = connectController({ frames: [navFrame], storage, scope: "1:9" });
    navRun.runTimer();
    navFrame.setAttribute("src", "/dashboard/metrics?time_range=7d");
    navFrame.innerHTML = "<div>navigated elsewhere</div>";
    navFrame.dispatch("turbo:frame-load");
    assert(storage.store[metricsKey("1:9")] === "<div>fresh metrics</div>",
      "content loaded under a different frame URL must not overwrite the cache");

    // 002: fetch errors keep the stale dim and release the queue.
    const errStorage = buildStorage({ [metricsKey("1:9")]: "<div>cached</div>" });
    const errFrame = buildFrame("dashboard-metrics", METRICS_SRC);
    const errSecond = buildFrame("dashboard-queue-health", QUEUE_SRC);
    const errRun = connectController({ frames: [errFrame, errSecond], storage: errStorage, scope: "1:9" });
    errRun.runTimer();
    errFrame.dispatch("turbo:fetch-request-error");
    assert(errFrame.classList.contains("opacity-60"), "fetch error should keep the stale dim");
    errRun.runTimer();
    assert(errSecond.getAttribute("src") === QUEUE_SRC, "queue should advance after a fetch error");

    // 002 + 007: frame-missing keeps stale content, advances the queue, caches nothing.
    const missingFrame = buildFrame("dashboard-metrics", METRICS_SRC);
    const missingSecond = buildFrame("dashboard-queue-health", QUEUE_SRC);
    const missingRun = connectController({ frames: [missingFrame, missingSecond], storage: errStorage, scope: "1:9" });
    missingRun.runTimer();
    missingFrame.innerHTML = "<div>login page</div>";
    assert(missingFrame.dispatch("turbo:frame-missing") === true,
      "frame-missing with stale content should prevent Turbo's fallback");
    assert(missingFrame.classList.contains("opacity-60"), "frame-missing should keep the stale dim");
    missingRun.runTimer();
    assert(missingSecond.getAttribute("src") === QUEUE_SRC, "queue should advance after frame-missing");
    assert(!Object.values(errStorage.store).includes("<div>login page</div>"),
      "a page without the matching frame must never be cached");
    const bareMissing = buildFrame("dashboard-metrics", METRICS_SRC);
    const bareRun = connectController({ frames: [bareMissing], storage: buildStorage(), scope: "1:9" });
    bareRun.runTimer();
    assert(bareMissing.dispatch("turbo:frame-missing") === false,
      "frame-missing without cached content should let Turbo show its fallback");

    // 006: Turbo snapshot restore — frames already carrying src keep their
    // rendered content, lose the dim, and stay out of the stagger queue.
    const restoreStorage = buildStorage({ [metricsKey("1:9")]: "<div>old cache</div>" });
    const restored = buildFrame("dashboard-metrics", METRICS_SRC, { html: "<div>snapshot</div>" });
    restored.setAttribute("src", METRICS_SRC);
    restored.classList.add("opacity-60", "transition-opacity");
    const freshFrame = buildFrame("dashboard-queue-health", QUEUE_SRC);
    const restoreRun = connectController({ frames: [restored, freshFrame], storage: restoreStorage, scope: "1:9" });
    assert(restored.innerHTML === "<div>snapshot</div>", "restore must not overwrite the snapshot with older cache");
    assert(!restored.classList.contains("opacity-60"), "restore must strip the stale dim");
    restoreRun.runTimer();
    assert(freshFrame.getAttribute("src") === QUEUE_SRC, "stagger should only load src-less frames");

    // 004: storage failures degrade to skeletons instead of breaking.
    const blockedFrame = buildFrame("dashboard-metrics", METRICS_SRC);
    connectController({ frames: [blockedFrame], storage: buildStorage({}, { throwOn: "getItem" }), scope: "1:9" });
    assert(blockedFrame.innerHTML.includes("skeleton"), "unreadable storage should fall back to the skeleton");
    const quotaFrame = buildFrame("dashboard-metrics", METRICS_SRC);
    const quotaRun = connectController({ frames: [quotaFrame], storage: buildStorage({}, { throwOn: "setItem" }), scope: "1:9" });
    quotaRun.runTimer();
    quotaFrame.dispatch("turbo:frame-load");

    // 005: a blank scope disables the cache entirely.
    const blankFrame = buildFrame("dashboard-metrics", METRICS_SRC);
    const blankStorage = buildStorage({ [`dashboard-frame:v1::dashboard-metrics:${METRICS_SRC}`]: "<div>x</div>" });
    connectController({ frames: [blankFrame], storage: blankStorage, scope: "" });
    assert(blankFrame.innerHTML.includes("skeleton"), "blank scope must disable hydration");
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe DashboardFramesControllerNodeHarness, :no_db do
  it "hydrates, dims, revalidates, and degrades the dashboard frame cache correctly" do
    stdout, stderr, status = described_class.run

    expect(status.success?).to be(true), <<~MESSAGE
      Node regression harness failed.
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
  end
end
