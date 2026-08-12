# frozen_string_literal: true

require "open3"
require "rails_helper"

class ChatControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/chat_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace('import consumer from "../channels/consumer"', 'const consumer = { subscriptions: { create: () => ({ perform() {}, unsubscribe() {} }) } }')
      .replace("export default class extends Controller {", "return class ChatController extends Controller {");

    const ChatController = new Function(transformed)();

    function makeController(overrides = {}) {
      const appended = [];
      const statusMessages = [];
      const controller = Object.create(ChatController.prototype);

      controller.messagesTarget = {
        querySelector: (sel) => null,
        append: (el) => appended.push(el)
      };
      controller.hasStatusTarget = true;
      controller.statusTarget = {
        get textContent() { return statusMessages[statusMessages.length - 1] || ""; },
        set textContent(v) { statusMessages.push(v); }
      };
      controller.hasTypingIndicatorTarget = false;
      controller.hasTokenUsageTarget = false;
      controller.autoScroll = false;
      controller.streaming = true;
      controller.currentStreamId = "test-id";
      controller.application = { getControllerForElementAndIdentifier: () => null };

      // Mock buildMessageElement to avoid needing a real DOM
      controller.buildMessageElement = (html) => html ? { outerHTML: html } : null;

      Object.assign(controller, overrides);

      return { controller, appended, statusMessages };
    }

    // --- Smooth-scroll test helpers --------------------------------------
    // smoothScrollTo relies on requestAnimationFrame + performance.now(),
    // neither of which exists in plain Node. The mock advances a virtual
    // clock by ~16 ms per frame so the 300 ms animation completes in a single
    // synchronous pass.
    function withMockedTimers(callback) {
      let time = 1000;
      const origPerf = globalThis.performance;
      const origRAF = globalThis.requestAnimationFrame;
      const origCAF = globalThis.cancelAnimationFrame;

      globalThis.performance = { now: () => time };
      globalThis.requestAnimationFrame = (cb) => { time += 16; cb(time); return 1; };
      globalThis.cancelAnimationFrame = () => {};

      try {
        callback();
      } finally {
        globalThis.performance = origPerf;
        globalThis.requestAnimationFrame = origRAF;
        globalThis.cancelAnimationFrame = origCAF;
      }
    }

    // smoothScrollTo checks window.matchMedia("(prefers-reduced-motion: reduce)")
    // to honor the user's OS-level motion preference. Node has no `window`, so
    // stub it; defaults to "no preference reduced" unless overridden.
    function withMatchMedia(matches, callback) {
      const origWindow = globalThis.window;
      globalThis.window = { matchMedia: () => ({ matches }) };

      try {
        callback();
      } finally {
        globalThis.window = origWindow;
      }
    }

    function testToolCallAppendsCardAndUpdatesStatus() {
      const { controller, appended, statusMessages } = makeController();

      controller.handleMessageToolCall({ html: "<div>tool-call</div>", tool_name: "list_projects" });

      if (appended.length !== 1) {
        throw new Error(`Expected 1 appended element for tool call, got ${appended.length}`);
      }

      const lastStatus = statusMessages[statusMessages.length - 1];
      if (!lastStatus || !lastStatus.includes("list_projects")) {
        throw new Error(`Expected status to mention tool name 'list_projects', got: ${lastStatus}`);
      }

      if (!controller.streaming) {
        throw new Error("Expected streaming to remain true after tool call");
      }
    }

    function testToolCallWithUnknownToolName() {
      const { controller, statusMessages } = makeController();

      controller.handleMessageToolCall({ html: "<div>tool-call</div>" });

      const lastStatus = statusMessages[statusMessages.length - 1];
      if (!lastStatus || !lastStatus.includes("tool")) {
        throw new Error(`Expected status to mention 'tool' for missing tool name, got: ${lastStatus}`);
      }
    }

    function testToolCallWithMissingHtmlDoesNotAppend() {
      const { controller, appended } = makeController();

      controller.handleMessageToolCall({ tool_name: "some_tool" });

      if (appended.length !== 0) {
        throw new Error(`Expected no appended elements when html is missing, got ${appended.length}`);
      }
    }

    function testToolResultAppendsCard() {
      const { controller, appended } = makeController();

      controller.handleMessageToolResult({ html: "<div>tool-result</div>" });

      if (appended.length !== 1) {
        throw new Error(`Expected 1 appended element for tool result, got ${appended.length}`);
      }

      if (!controller.streaming) {
        throw new Error("Expected streaming to remain true after tool result");
      }
    }

    function testToolResultWithMissingHtmlDoesNotAppend() {
      const { controller, appended } = makeController();

      controller.handleMessageToolResult({});

      if (appended.length !== 0) {
        throw new Error(`Expected no appended elements when html is missing, got ${appended.length}`);
      }
    }

    function testMessageCompleteResetsStreamingState() {
      const { controller } = makeController({
        streaming: true,
        incrementTokenUsage: () => {},
        scrollToBottom: () => {},
        toggleTyping: () => {},
        setStatus: () => {},
        dispatchChatState: () => {},
        setBusy: function(busy) { this.streaming = busy; }
      });

      controller.handleMessageComplete({ tokens: { input: 10, output: 5 } });

      if (controller.streaming) {
        throw new Error("Expected streaming to be false after message_complete");
      }
    }

    function testToolEventsDoNotResetStreamingBeforeComplete() {
      const { controller, appended } = makeController({ streaming: true });

      controller.handleMessageToolCall({ html: "<div>call</div>", tool_name: "run_query" });
      controller.handleMessageToolResult({ html: "<div>result</div>" });

      if (!controller.streaming) {
        throw new Error("Expected streaming to remain true through tool call and result — only message_complete should reset it");
      }

      if (appended.length !== 2) {
        throw new Error(`Expected 2 appended elements (call + result), got ${appended.length}`);
      }
    }

    function testHandleEventDispatchesToolCall() {
      const dispatched = [];
      const { controller } = makeController();
      controller.handleMessageToolCall = (data) => dispatched.push({ handler: "tool_call", data });
      controller.handleMessageToolResult = (data) => dispatched.push({ handler: "tool_result", data });

      controller.handleEvent({ type: "message_tool_call", html: "<div/>", tool_name: "x" });
      controller.handleEvent({ type: "message_tool_result", html: "<div/>" });

      if (dispatched.length !== 2) {
        throw new Error(`Expected 2 dispatched events, got ${dispatched.length}`);
      }
      if (dispatched[0].handler !== "tool_call") {
        throw new Error(`Expected first dispatch to be 'tool_call', got '${dispatched[0].handler}'`);
      }
      if (dispatched[1].handler !== "tool_result") {
        throw new Error(`Expected second dispatch to be 'tool_result', got '${dispatched[1].handler}'`);
      }
    }

    function testFallbackNoticeRemovesStaleToolCards() {
      const removed = [];
      const { controller, appended } = makeController({
        buildMessageElement: (html) => html ? { outerHTML: html, remove: () => { removed.push(html); } } : null
      });

      controller.handleMessageStart({ message_id: "stream-1", model: "gpt-4o" });
      controller.handleMessageToolCall({ html: "<div>tool-call</div>", tool_name: "search" });
      controller.handleMessageToolResult({ html: "<div>tool-result</div>" });

      if (appended.length !== 2) {
        throw new Error(`Expected 2 appended tool cards before fallback, got ${appended.length}`);
      }

      // A fallback notice must tear down the failed attempt's tool cards along
      // with the in-flight assistant bubble — otherwise the UI keeps showing
      // tool activity whose backing rows FallbackLoop#discard_partial_attempt
      // deleted.
      controller.handleMessageCreated({ html: "<div>fallback notice</div>", fallback_notice: true });

      if (removed.length !== 2) {
        throw new Error(`Expected both stale tool cards removed on fallback notice, got ${removed.length}`);
      }

      if ((controller.currentAttemptToolCards || []).length !== 0) {
        throw new Error("Expected tracked tool cards to be cleared after fallback notice");
      }
    }

    function testRegularMessageCreatedKeepsAttemptToolCards() {
      const removed = [];
      const { controller } = makeController({
        buildMessageElement: (html) => html ? { outerHTML: html, remove: () => { removed.push(html); } } : null
      });

      controller.handleMessageStart({ message_id: "stream-1", model: "gpt-4o" });
      controller.handleMessageToolCall({ html: "<div>tool-call</div>", tool_name: "search" });
      controller.handleMessageCreated({ html: "<div>assistant reply</div>" });

      if (removed.length !== 0) {
        throw new Error(`Expected tool cards to survive a non-fallback message_created, removed ${removed.length}`);
      }
    }

    function testCapabilityChangedUpdatesPanelIconAndActions() {
      const actions = [];
      const repos = [];
      let iconClassName = "";
      let iconSetAttributeCalls = 0;
      const { controller, statusMessages } = makeController({
        capabilityBadgeTargets: [ { textContent: "", className: "", dataset: {} } ],
        capabilityPanelTargets: [ { dataset: {} } ],
        capabilityLabelTargets: [ { textContent: "" } ],
        capabilityIconTargets: [ {
          get className() {
            throw new Error("SVG className setter should not be used");
          },
          setAttribute(name, value) {
            if (name !== "class") {
              throw new Error(`Expected setAttribute to target class, got ${name}`);
            }

            iconSetAttributeCalls += 1;
            iconClassName = value;
          }
        } ],
        updateCapabilityActions: (capability) => actions.push(capability),
        updateCapabilityRepos: (entries) => repos.push(entries),
        setStatus: (message) => statusMessages.push(message)
      });

      controller.handleCapabilityChanged({
        container_capability: "ready",
        container_capability_label: "Workspace ready",
        cloned_repos: [ { project_id: 1, project_name: "Repo" } ]
      });

      if (controller.capabilityBadgeTargets[0].textContent !== "Workspace ready") {
        throw new Error(`Expected capability badge text to update, saw '${controller.capabilityBadgeTargets[0].textContent}'`);
      }

      if (controller.capabilityBadgeTargets[0].dataset.capability !== "ready") {
        throw new Error(`Expected capability badge dataset to update, saw '${controller.capabilityBadgeTargets[0].dataset.capability}'`);
      }

      if (!controller.capabilityBadgeTargets[0].className.includes("bg-green-100")) {
        throw new Error(`Expected capability badge classes to switch to ready, saw '${controller.capabilityBadgeTargets[0].className}'`);
      }

      if (controller.capabilityPanelTargets[0].dataset.chatCapability !== "ready") {
        throw new Error(`Expected capability panel dataset to update, saw '${controller.capabilityPanelTargets[0].dataset.chatCapability}'`);
      }

      if (controller.capabilityLabelTargets[0].textContent !== "Workspace ready") {
        throw new Error(`Expected capability label text to update, saw '${controller.capabilityLabelTargets[0].textContent}'`);
      }

      if (iconSetAttributeCalls !== 1) {
        throw new Error(`Expected capability icon classes to be set once, saw ${iconSetAttributeCalls}`);
      }

      if (iconClassName !== "h-4 w-4 text-green-500 fill-current") {
        throw new Error(`Expected capability icon classes to switch to ready, saw '${iconClassName}'`);
      }

      if (actions.length !== 1 || actions[0] !== "ready") {
        throw new Error(`Expected capability actions to update once with 'ready', saw ${JSON.stringify(actions)}`);
      }

      if (repos.length !== 1 || repos[0].length !== 1) {
        throw new Error(`Expected capability repos to update once, saw ${JSON.stringify(repos)}`);
      }

      if (statusMessages[statusMessages.length - 1] !== "Workspace ready") {
        throw new Error(`Expected ready capability to set a ready status message, saw '${statusMessages[statusMessages.length - 1]}'`);
      }
    }

    function testSystemNoticeReplacementTargetsTopLevelElement() {
      const replacement = { outerHTML: "<details>replacement</details>" };
      let replacedWith = null;
      const renderedRoot = {
        replaceWith: (element) => { replacedWith = element; }
      };
      const messageElement = {
        closest: (selector) => selector === "details, div.flex.justify-start, div.justify-end, div.justify-center" ? renderedRoot : null
      };
      const { controller } = makeController({
        buildMessageElement: () => replacement,
        messageElementById: () => messageElement,
        scrollToBottom: () => {}
      });

      controller.handleMessageCreated({ html: replacement.outerHTML, message_id: "system-1" });

      if (replacedWith !== replacement) {
        throw new Error("Expected handleMessageCreated to replace the top-level rendered system notice element");
      }
    }

    function testSystemNoticeDeletionTargetsTopLevelElement() {
      let removed = false;
      const renderedRoot = {
        remove: () => { removed = true; }
      };
      const messageElement = {
        closest: (selector) => selector === "details, div.flex.justify-start, div.justify-end, div.justify-center" ? renderedRoot : null
      };
      const { controller } = makeController({
        messageElementById: () => messageElement
      });

      controller.handleMessageDeleted({ message_id: "system-1" });

      if (!removed) {
        throw new Error("Expected handleMessageDeleted to remove the top-level rendered system notice element");
      }
    }

    function testSmoothScrollToAnimatesContainer() {
      let scrollTop = 0;
      const { controller } = makeController({
        containerTarget: {
          get scrollTop() { return scrollTop; },
          set scrollTop(v) { scrollTop = v; },
          scrollHeight: 1000,
          clientHeight: 200
        }
      });

      withMatchMedia(false, () => withMockedTimers(() => controller.smoothScrollTo(1000)));

      if (Math.abs(scrollTop - 1000) > 1) {
        throw new Error(`Expected scrollTop to animate to ~1000, got ${scrollTop}`);
      }
    }

    function testSmoothScrollToNoOpForZeroDistance() {
      let sets = 0;
      const { controller } = makeController({
        containerTarget: {
          get scrollTop() { return 500; },
          set scrollTop(v) { sets += 1; },
          scrollHeight: 1000,
          clientHeight: 200
        }
      });

      withMatchMedia(false, () => withMockedTimers(() => controller.smoothScrollTo(500)));

      if (sets !== 0) {
        throw new Error(`Expected no scrollTop writes when distance is 0, got ${sets}`);
      }
    }

    function testSmoothScrollToJumpsInstantlyWhenReducedMotionPreferred() {
      let scrollTop = 0;
      const { controller } = makeController({
        containerTarget: {
          get scrollTop() { return scrollTop; },
          set scrollTop(v) { scrollTop = v; },
          scrollHeight: 1000,
          clientHeight: 200
        }
      });

      withMatchMedia(true, () => controller.smoothScrollTo(1000));

      if (scrollTop !== 1000) {
        throw new Error(`Expected reduced-motion scroll to jump instantly to 1000, got ${scrollTop}`);
      }
    }

    function testScrollToInputScrollsToBottom() {
      let scrolledTo = null;
      const { controller } = makeController({
        containerTarget: { scrollTop: 0, scrollHeight: 800, clientHeight: 200 }
      });
      controller.smoothScrollTo = (target) => { scrolledTo = target; };

      controller.scrollToInput();

      if (scrolledTo !== 800) {
        throw new Error(`Expected scrollToInput to target scrollHeight (800), got ${scrolledTo}`);
      }
    }

    function testScrollToTopScrollsToZero() {
      let scrolledTo = null;
      const { controller } = makeController({
        containerTarget: { scrollTop: 400, scrollHeight: 800, clientHeight: 200 }
      });
      controller.smoothScrollTo = (target) => { scrolledTo = target; };

      controller.scrollToTop();

      if (scrolledTo !== 0) {
        throw new Error(`Expected scrollToTop to target 0, got ${scrolledTo}`);
      }
    }

    function testHandleScrollShowsBackToTopWhenScrolled() {
      const toggles = [];
      const { controller } = makeController({
        containerTarget: { scrollTop: 300, scrollHeight: 2000, clientHeight: 400 },
        hasBackToTopTarget: true,
        backToTopTarget: {
          classList: { toggle: (cls, cond) => toggles.push({ cls, cond }) }
        }
      });

      controller.handleScroll();

      const visible = toggles.find((t) => t.cls === "opacity-100");
      if (!visible || visible.cond !== true) {
        throw new Error("Expected back-to-top to become visible when scrollTop > 200");
      }

      const interactive = toggles.find((t) => t.cls === "pointer-events-auto");
      if (!interactive || interactive.cond !== true) {
        throw new Error("Expected back-to-top to become interactive when scrollTop > 200");
      }
    }

    function testHandleScrollHidesBackToTopAtTop() {
      const toggles = [];
      const { controller } = makeController({
        containerTarget: { scrollTop: 50, scrollHeight: 2000, clientHeight: 400 },
        hasBackToTopTarget: true,
        backToTopTarget: {
          classList: { toggle: (cls, cond) => toggles.push({ cls, cond }) }
        }
      });

      controller.handleScroll();

      const hidden = toggles.find((t) => t.cls === "opacity-0");
      if (!hidden || hidden.cond !== true) {
        throw new Error("Expected back-to-top to be hidden when scrollTop <= 200");
      }
    }

    function run() {
      testToolCallAppendsCardAndUpdatesStatus();
      testToolCallWithUnknownToolName();
      testToolCallWithMissingHtmlDoesNotAppend();
      testToolResultAppendsCard();
      testToolResultWithMissingHtmlDoesNotAppend();
      testMessageCompleteResetsStreamingState();
      testToolEventsDoNotResetStreamingBeforeComplete();
      testHandleEventDispatchesToolCall();
      testFallbackNoticeRemovesStaleToolCards();
      testRegularMessageCreatedKeepsAttemptToolCards();
      testCapabilityChangedUpdatesPanelIconAndActions();
      testSystemNoticeReplacementTargetsTopLevelElement();
      testSystemNoticeDeletionTargetsTopLevelElement();
      testSmoothScrollToAnimatesContainer();
      testSmoothScrollToNoOpForZeroDistance();
      testSmoothScrollToJumpsInstantlyWhenReducedMotionPreferred();
      testScrollToInputScrollsToBottom();
      testScrollToTopScrollsToZero();
      testHandleScrollShowsBackToTopWhenScrolled();
      testHandleScrollHidesBackToTopAtTop();
    }

    try {
      run();
    } catch (error) {
      console.error(error.message || error);
      process.exit(1);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ChatControllerNodeHarness, :no_db do
  it "keeps chat tool streaming and live capability UI updates consistent" do
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
