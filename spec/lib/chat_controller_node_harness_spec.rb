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
        querySelectorAll: (sel) => [],
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

      // Stimulus sets hasContainerTarget to true when the container element
      // exists in the DOM. Mirror that so the defensive guards in handleScroll,
      // scrollToBottom, scrollToInput, and smoothScrollTo exercise their real
      // path whenever a containerTarget is provided.
      if ("containerTarget" in controller) {
        controller.hasContainerTarget = true;
      }

      // Same for messagesTarget — lastAssistantTextResponse guards on
      // hasMessagesTarget before walking the transcript, and the jump-to-
      // latest tests need that guard lifted to exercise the anchor path.
      if ("messagesTarget" in controller) {
        controller.hasMessagesTarget = true;
      }

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

    // updateViewportHeight reads window.scrollY so the measured panel offset is
    // document-relative (scroll-invariant). Node has no `window`; stub it.
    function withScrollY(scrollY, callback) {
      const origWindow = globalThis.window;
      globalThis.window = { scrollY };

      try {
        callback();
      } finally {
        globalThis.window = origWindow;
      }
    }

    // restorePendingContent dispatches a plain window.Event. Node has no
    // `window`; stub a minimal Event constructor.
    function withWindowEvent(callback) {
      const origWindow = globalThis.window;
      globalThis.window = {
        Event: class {
          constructor(type, options = {}) {
            this.type = type;
            this.bubbles = Boolean(options.bubbles);
          }
        }
      };

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

      controller.handleMessageComplete({ message_id: "test-id", tokens: { input: 10, output: 5 } });

      if (controller.streaming) {
        throw new Error("Expected streaming to be false after message_complete");
      }
    }

    // A send is tracked before the server has confirmed anything (message_start
    // travels over the same socket) so a later rejection — e.g. a token-limit
    // error — can restore what the user typed.
    function testSendMessageTracksPendingContentForRestoration() {
      const performed = [];
      const { controller } = makeController({
        streaming: false,
        subscription: { perform: (action, data) => performed.push({ action, data }) },
        setBusy: () => {}
      });

      controller.sendMessage({ detail: { content: "Hello there" } });

      if (controller.pendingContent !== "Hello there") {
        throw new Error(`Expected pendingContent to be tracked, got '${controller.pendingContent}'`);
      }
      if (performed.length !== 1 || performed[0].action !== "send_message") {
        throw new Error("Expected sendMessage to perform send_message over the subscription");
      }
    }

    // A rejected send (e.g. a token-limit error) must not silently discard the
    // user's typed text — chat-input#send already cleared the textarea
    // optimistically, so handleError has to put it back. Only the token-limit
    // rejection carries limit_type: it fires before persist_user_message, so
    // the input's text was never persisted/rendered elsewhere.
    function testHandleErrorRestoresPendingContentIntoInput() {
      withWindowEvent(() => {
        let restoredValue = null;
        const dispatchedEvents = [];
        const { controller } = makeController({
          pendingContent: "Draft message",
          hasInputTarget: true,
          inputTarget: {
            set value(v) { restoredValue = v; },
            get value() { return restoredValue; },
            dispatchEvent: (event) => dispatchedEvents.push(event.type)
          },
          setBusy: () => {},
          toggleTyping: () => {},
          setStatus: () => {},
          removePendingAssistantMessage: () => {}
        });

        controller.handleError({
          message_id: "test-id",
          message: "Chat token limit reached (session): 5000000 tokens",
          limit_type: "session"
        });

        if (restoredValue !== "Draft message") {
          throw new Error(`Expected input value to be restored, got '${restoredValue}'`);
        }
        if (controller.pendingContent !== null) {
          throw new Error("Expected pendingContent to be cleared after restoring it");
        }
        if (!dispatchedEvents.includes("input")) {
          throw new Error("Expected an input event so chat-input resizes and updates the char count");
        }
      });
    }

    function testHandleErrorNoOpsWithoutPendingContent() {
      withWindowEvent(() => {
        let restoredValue = "unchanged";
        const { controller } = makeController({
          pendingContent: null,
          hasInputTarget: true,
          inputTarget: {
            set value(v) { restoredValue = v; },
            get value() { return restoredValue; },
            dispatchEvent: () => { throw new Error("Expected no dispatch when there is no pending content"); }
          },
          setBusy: () => {},
          toggleTyping: () => {},
          setStatus: () => {},
          removePendingAssistantMessage: () => {}
        });

        controller.handleError({ message_id: "test-id", message: "boom", limit_type: "session" });

        if (restoredValue !== "unchanged") {
          throw new Error("Expected no restoration when there is no pending content");
        }
      });
    }

    // Mid-loop failures (provider fallback exhaustion, rate limits, unexpected
    // errors) fire after persist_user_message already broadcast the user's
    // message via message_created — restoring here would duplicate it in the
    // input. These errors never carry limit_type, so they must not restore.
    function testHandleErrorDoesNotRestoreWithoutLimitType() {
      withWindowEvent(() => {
        let restoredValue = "unchanged";
        const { controller } = makeController({
          pendingContent: "Already rendered as a message",
          hasInputTarget: true,
          inputTarget: {
            set value(v) { restoredValue = v; },
            get value() { return restoredValue; },
            dispatchEvent: () => { throw new Error("Expected no dispatch when the error lacks limit_type"); }
          },
          setBusy: () => {},
          toggleTyping: () => {},
          setStatus: () => {},
          removePendingAssistantMessage: () => {}
        });

        controller.handleError({ message_id: "test-id", message: "Provider unavailable" });

        if (restoredValue !== "unchanged") {
          throw new Error("Expected no restoration for an error without limit_type");
        }
        if (controller.pendingContent !== "Already rendered as a message") {
          throw new Error("Expected pendingContent to be left untouched when restoration is skipped");
        }
      });
    }

    // Success paths (turn completed, or paused for tool approval) must clear
    // pendingContent — otherwise a later, unrelated error would resurrect
    // already-sent text into the input.
    function testMessageCompleteClearsPendingContent() {
      const { controller } = makeController({
        pendingContent: "Already sent",
        incrementTokenUsage: () => {},
        scrollToBottom: () => {},
        toggleTyping: () => {},
        setStatus: () => {},
        dispatchChatState: () => {},
        setBusy: function(busy) { this.streaming = busy; }
      });

      controller.handleMessageComplete({ message_id: "test-id", tokens: { input: 10, output: 5 } });

      if (controller.pendingContent !== null) {
        throw new Error("Expected pendingContent to be cleared after message_complete");
      }
    }

    function testToolConfirmationClearsPendingContent() {
      const { controller } = makeController({
        pendingContent: "Already sent",
        setBusy: () => {},
        toggleTyping: () => {},
        setStatus: () => {},
        scrollToBottom: () => {}
      });

      controller.handleMessageToolConfirmation({ stream_message_id: "test-id", tool_name: "trigger_agent_run" });

      if (controller.pendingContent !== null) {
        throw new Error("Expected pendingContent to be cleared after a tool confirmation pause");
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

    // @spec CHAT-SCROLL-001 — The top-bar "Jump to latest" button and the
    // sticky jump-to-last-response button both smooth-scroll to the top of
    // the last assistant text message. The target is the container-relative
    // scrollTop of the anchor (not offsetTop, which is unreliable through
    // nested wrappers, and not scrollHeight, which would jump past tool
    // calls appended after the response).
    function testScrollToLatestResponseSmoothScrollsToAnchor() {
      const anchor = { getBoundingClientRect: () => ({ top: 250 }) };
      let scrolledTo = null;
      const { controller } = makeController({
        containerTarget: {
          get scrollTop() { return 100; },
          set scrollTop(v) {},
          scrollHeight: 1500,
          clientHeight: 400,
          getBoundingClientRect: () => ({ top: 50 })
        },
        messagesTarget: {
          querySelectorAll: () => [ anchor ],
          append: () => {}
        }
      });
      controller.smoothScrollTo = (target) => { scrolledTo = target; };

      controller.scrollToLatestResponse();

      // scrollTop (100) + (anchorRect.top 250 - containerRect.top 50) = 300
      if (scrolledTo !== 300) {
        throw new Error(`Expected scrollToLatestResponse to target 300 (container-relative anchor offset), got ${scrolledTo}`);
      }
    }

    // @spec CHAT-SCROLL-001 — A new chat or one whose last turn is a user
    // message has no assistant text yet; the click still does something
    // useful by landing on the bottom of the transcript (same target as
    // "Jump to input").
    function testScrollToLatestResponseFallsBackToBottom() {
      let scrolledTo = null;
      const { controller } = makeController({
        containerTarget: { scrollTop: 0, scrollHeight: 800, clientHeight: 200 },
        messagesTarget: {
          querySelectorAll: () => [],
          append: () => {}
        }
      });
      controller.smoothScrollTo = (target) => { scrolledTo = target; };

      controller.scrollToLatestResponse();

      if (scrolledTo !== 800) {
        throw new Error(`Expected scrollToLatestResponse to fall back to scrollHeight (800), got ${scrolledTo}`);
      }
    }

    // @spec CHAT-SCROLL-001 — The on-load jump is instant: it assigns
    // containerTarget.scrollTop directly so the user lands on the latest
    // response without seeing an animated scroll on every chat load.
    function testJumpToLatestResponseOnLoadSetsScrollTopInstantly() {
      const anchor = { getBoundingClientRect: () => ({ top: 300 }) };
      let scrollTopWrites = 0;
      let lastScrollTop = null;
      const { controller } = makeController({
        containerTarget: {
          get scrollTop() { return 0; },
          set scrollTop(v) { scrollTopWrites += 1; lastScrollTop = v; },
          scrollHeight: 1500,
          clientHeight: 400,
          getBoundingClientRect: () => ({ top: 100 })
        },
        messagesTarget: {
          querySelectorAll: () => [ anchor ],
          append: () => {}
        }
      });
      // Pin Turbo to an advance action so we exercise the forward-nav path
      // without polluting other tests in this run.
      const origTurbo = globalThis.Turbo;

      try {
        globalThis.Turbo = { navigator: { currentVisit: { action: "advance" } } };
        controller.jumpToLatestResponseOnLoad();
      } finally {
        globalThis.Turbo = origTurbo;
      }

      if (scrollTopWrites !== 1) {
        throw new Error(`Expected exactly one scrollTop write for the on-load jump, got ${scrollTopWrites}`);
      }
      // 0 + (300 - 100) = 200
      if (lastScrollTop !== 200) {
        throw new Error(`Expected on-load jump to set scrollTop to 200, got ${lastScrollTop}`);
      }
    }

    // @spec CHAT-SCROLL-001 — Descendant chat-message controllers connect
    // after chat and replace their placeholder text with rendered markdown.
    // Defer the initial measurement one frame so layout shifts above the last
    // response cannot leave its opening outside the viewport.
    function testConnectDefersInitialJumpUntilAfterChildControllersRender() {
      const { controller } = makeController({ sessionIdValue: 42 });
      const origWindow = globalThis.window;
      const origRAF = globalThis.requestAnimationFrame;
      let scheduledJump = null;
      let jumps = 0;

      try {
        globalThis.window = { addEventListener() {} };
        globalThis.requestAnimationFrame = (callback) => {
          scheduledJump = callback;
          return 1;
        };
        controller.updateViewportHeight = () => {};
        controller.handleScroll = () => {};
        controller.jumpToLatestResponseOnLoad = () => { jumps += 1; };

        controller.connect();

        if (jumps !== 0 || !scheduledJump) {
          throw new Error("Expected connect to defer the initial jump by one animation frame");
        }

        scheduledJump();
      } finally {
        globalThis.window = origWindow;
        globalThis.requestAnimationFrame = origRAF;
      }

      if (jumps !== 1) {
        throw new Error(`Expected the deferred frame to perform one initial jump, got ${jumps}`);
      }
    }

    // @spec CHAT-SCROLL-001 — Leaving a chat records the overflow
    // container's position under its session-scoped key so a later Turbo
    // restoration can return the reader to the same place.
    function testDisconnectRemembersTranscriptScrollPosition() {
      const writes = [];
      const { controller } = makeController({
        sessionIdValue: 42,
        containerTarget: { scrollTop: 475 },
        subscription: { unsubscribe() {} },
        boundUpdateViewportHeight: () => {}
      });
      const origWindow = globalThis.window;
      const origSessionStorage = globalThis.sessionStorage;

      try {
        globalThis.window = { removeEventListener() {} };
        globalThis.sessionStorage = {
          setItem: (key, value) => writes.push({ key, value })
        };
        controller.disconnect();
      } finally {
        globalThis.window = origWindow;
        globalThis.sessionStorage = origSessionStorage;
      }

      if (writes.length !== 1 || writes[0].key !== "paid:chat-scroll:42" || writes[0].value !== "475") {
        throw new Error(`Expected disconnect to save scrollTop 475 for session 42, got ${JSON.stringify(writes)}`);
      }
    }

    // @spec CHAT-SCROLL-001 — Turbo restores the document scroll position,
    // but not this overflow container. A restoration visit must recover the
    // saved container position rather than showing the oldest transcript
    // messages or jumping to the latest response.
    function testJumpToLatestResponseOnLoadRestoresTranscriptPosition() {
      const anchor = { getBoundingClientRect: () => ({ top: 300 }) };
      let scrollTopWrites = 0;
      let lastScrollTop = null;
      const { controller } = makeController({
        sessionIdValue: 42,
        containerTarget: {
          get scrollTop() { return 0; },
          set scrollTop(v) { scrollTopWrites += 1; lastScrollTop = v; },
          scrollHeight: 1500,
          clientHeight: 400,
          getBoundingClientRect: () => ({ top: 100 })
        },
        messagesTarget: {
          querySelectorAll: () => [ anchor ],
          append: () => {}
        }
      });
      const origTurbo = globalThis.Turbo;
      const origSessionStorage = globalThis.sessionStorage;

      try {
        globalThis.Turbo = { navigator: { currentVisit: { action: "restore" } } };
        globalThis.sessionStorage = {
          getItem: (key) => key === "paid:chat-scroll:42" ? "475" : null
        };
        controller.jumpToLatestResponseOnLoad();
      } finally {
        globalThis.Turbo = origTurbo;
        globalThis.sessionStorage = origSessionStorage;
      }

      if (scrollTopWrites !== 1 || lastScrollTop !== 475) {
        throw new Error(`Expected Turbo restoration to recover scrollTop 475, got ${lastScrollTop}`);
      }
    }

    // @spec CHAT-SCROLL-001 — A restoration in another tab (or after storage
    // fails) has no session-scoped position to restore. Treat the absent value
    // as absent rather than Number(null) = 0, then use the ordinary latest
    // response target so the user does not land at the oldest messages.
    function testJumpToLatestResponseOnLoadFallsBackWhenTranscriptPositionIsMissing() {
      const anchor = { getBoundingClientRect: () => ({ top: 300 }) };
      let lastScrollTop = null;
      const { controller } = makeController({
        sessionIdValue: 42,
        containerTarget: {
          get scrollTop() { return 0; },
          set scrollTop(v) { lastScrollTop = v; },
          scrollHeight: 1500,
          clientHeight: 400,
          getBoundingClientRect: () => ({ top: 100 })
        },
        messagesTarget: {
          querySelectorAll: () => [ anchor ],
          append: () => {}
        }
      });
      const origTurbo = globalThis.Turbo;
      const origSessionStorage = globalThis.sessionStorage;

      try {
        globalThis.Turbo = { navigator: { currentVisit: { action: "restore" } } };
        globalThis.sessionStorage = { getItem: () => null };
        controller.jumpToLatestResponseOnLoad();
      } finally {
        globalThis.Turbo = origTurbo;
        globalThis.sessionStorage = origSessionStorage;
      }

      if (lastScrollTop !== 200) {
        throw new Error(`Expected a missing restoration position to jump to latest response at 200, got ${lastScrollTop}`);
      }
    }

    // @spec CHAT-SCROLL-001 — A chat with no assistant text yet (new chat,
    // or one ending in a user message) jumps to the bottom on load, same
    // as the button-click fallback.
    function testJumpToLatestResponseOnLoadFallsBackToBottom() {
      let lastScrollTop = null;
      const { controller } = makeController({
        containerTarget: {
          get scrollTop() { return 0; },
          set scrollTop(v) { lastScrollTop = v; },
          scrollHeight: 800,
          clientHeight: 200,
          getBoundingClientRect: () => ({ top: 0 })
        },
        messagesTarget: {
          querySelectorAll: () => [],
          append: () => {}
        }
      });
      const origTurbo = globalThis.Turbo;

      try {
        globalThis.Turbo = { navigator: { currentVisit: { action: "advance" } } };
        controller.jumpToLatestResponseOnLoad();
      } finally {
        globalThis.Turbo = origTurbo;
      }

      if (lastScrollTop !== 800) {
        throw new Error(`Expected on-load jump to fall back to scrollHeight (800), got ${lastScrollTop}`);
      }
    }

    // @spec CHAT-SCROLL-001 — A direct scrollTop assignment does not emit a
    // scroll event. The on-load fallback must therefore recalculate the
    // sticky control after arriving at the bottom, rather than leaving a
    // visible button whose action is a no-op.
    function testJumpToLatestResponseOnLoadUpdatesStickyControl() {
      const toggles = [];
      const { controller } = makeController({
        containerTarget: {
          scrollTop: 0,
          scrollHeight: 800,
          clientHeight: 200,
          getBoundingClientRect: () => ({ top: 0 })
        },
        messagesTarget: {
          querySelectorAll: () => [],
          append: () => {}
        },
        hasStickyJumpToLatestTarget: true,
        stickyJumpToLatestTarget: {
          classList: { toggle: (cls, cond) => toggles.push({ cls, cond }) }
        }
      });
      const origTurbo = globalThis.Turbo;

      try {
        globalThis.Turbo = { navigator: { currentVisit: { action: "advance" } } };
        controller.jumpToLatestResponseOnLoad();
      } finally {
        globalThis.Turbo = origTurbo;
      }

      const hidden = toggles.find((t) => t.cls === "opacity-0");
      if (!hidden || hidden.cond !== true) {
        throw new Error("Expected on-load fallback to hide sticky jump-to-latest at the bottom");
      }
    }

    // @spec CHAT-SCROLL-001 — Show the sticky jump-to-latest button when
    // the user has scrolled past the start of the last assistant response
    // (anchor's top is above the container's top — viewport-relative).
    function testHandleScrollShowsStickyJumpToLatestWhenAnchorAboveViewport() {
      const anchor = { getBoundingClientRect: () => ({ top: -50 }) };
      const toggles = [];
      const { controller } = makeController({
        containerTarget: {
          scrollTop: 800,
          scrollHeight: 2000,
          clientHeight: 400,
          getBoundingClientRect: () => ({ top: 0 })
        },
        messagesTarget: {
          querySelectorAll: () => [ anchor ],
          append: () => {}
        },
        hasStickyJumpToLatestTarget: true,
        stickyJumpToLatestTarget: {
          classList: { toggle: (cls, cond) => toggles.push({ cls, cond }) }
        }
      });

      controller.handleScroll();

      const visible = toggles.find((t) => t.cls === "opacity-100");
      if (!visible || visible.cond !== true) {
        throw new Error("Expected sticky jump-to-latest to become visible when the anchor is above the viewport top");
      }
    }

    // @spec CHAT-SCROLL-001 — Hide the sticky button when the anchor is in
    // view, so a click would be a no-op (a fixed pixel threshold would
    // show it even when there's nothing to jump to).
    function testHandleScrollHidesStickyJumpToLatestWhenAnchorInView() {
      const anchor = { getBoundingClientRect: () => ({ top: 200 }) };
      const toggles = [];
      const { controller } = makeController({
        containerTarget: {
          scrollTop: 100,
          scrollHeight: 2000,
          clientHeight: 400,
          getBoundingClientRect: () => ({ top: 0 })
        },
        messagesTarget: {
          querySelectorAll: () => [ anchor ],
          append: () => {}
        },
        hasStickyJumpToLatestTarget: true,
        stickyJumpToLatestTarget: {
          classList: { toggle: (cls, cond) => toggles.push({ cls, cond }) }
        }
      });

      controller.handleScroll();

      const hidden = toggles.find((t) => t.cls === "opacity-0");
      if (!hidden || hidden.cond !== true) {
        throw new Error("Expected sticky jump-to-latest to stay hidden when the anchor is already in view");
      }
    }

    // @spec CHAT-SCROLL-001 — Without an assistant anchor, the sticky
    // button uses the bottom-distance fallback (same rule the auto-scroll
    // uses), so it tracks "is the bottom visible?" rather than guessing a
    // pixel threshold.
    function testHandleScrollStickyJumpToLatestFallsBackToBottomDistance() {
      const toggles = [];
      const { controller } = makeController({
        containerTarget: { scrollTop: 0, scrollHeight: 1000, clientHeight: 200 },
        messagesTarget: {
          querySelectorAll: () => [],
          append: () => {}
        },
        hasStickyJumpToLatestTarget: true,
        stickyJumpToLatestTarget: {
          classList: { toggle: (cls, cond) => toggles.push({ cls, cond }) }
        }
      });

      controller.handleScroll();

      const visible = toggles.find((t) => t.cls === "opacity-100");
      if (!visible || visible.cond !== true) {
        throw new Error("Expected sticky jump-to-latest to be visible when the bottom is far away and no anchor exists");
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

    function testUpdateViewportHeightTracksPanelOffset() {
      const styleWrites = [];
      const { controller } = makeController({
        element: {
          getBoundingClientRect: () => ({ top: 123.2 }),
          style: {
            setProperty: (name, value) => styleWrites.push({ name, value })
          }
        }
      });

      withScrollY(0, () => controller.updateViewportHeight());

      if (styleWrites.length !== 1) {
        throw new Error(`Expected 1 viewport height style write, got ${styleWrites.length}`);
      }
      if (styleWrites[0].name !== "--chat-panel-offset-top") {
        throw new Error(`Expected viewport offset variable write, got ${styleWrites[0].name}`);
      }
      if (styleWrites[0].value !== "124px") {
        throw new Error(`Expected viewport offset to round up to 124px, got ${styleWrites[0].value}`);
      }
    }

    function testUpdateViewportHeightClampsNegativeOffset() {
      const styleWrites = [];
      const { controller } = makeController({
        element: {
          getBoundingClientRect: () => ({ top: -20 }),
          style: {
            setProperty: (name, value) => styleWrites.push({ name, value })
          }
        }
      });

      withScrollY(0, () => controller.updateViewportHeight());

      if (styleWrites[0].value !== "0px") {
        throw new Error(`Expected negative viewport offset to clamp to 0px, got ${styleWrites[0].value}`);
      }
    }

    // A restoration visit can connect the controller while the page is already
    // scrolled. Measuring viewport-relative would then understate the offset
    // (here: 123 - 400, clamped to 0) and size the panel a whole viewport tall,
    // handing the scroll role back to the document.
    function testUpdateViewportHeightIsScrollInvariant() {
      const styleWrites = [];
      const { controller } = makeController({
        element: {
          getBoundingClientRect: () => ({ top: 123.2 - 400 }),
          style: {
            setProperty: (name, value) => styleWrites.push({ name, value })
          }
        }
      });

      withScrollY(400, () => controller.updateViewportHeight());

      if (styleWrites[0].value !== "124px") {
        throw new Error(`Expected scrolled page to measure the same 124px offset, got ${styleWrites[0].value}`);
      }
    }

    // The reopen CTA lives inside the workspace disclosure, so un-hiding it is
    // not enough — a chat whose workspace stops would show no way to recover.
    function testStoppedCapabilityUnfoldsItsDisclosure() {
      const attributes = [];
      const details = { setAttribute: (name, value) => attributes.push({ name, value }) };
      const reopenForm = {
        classList: { contains: (cls) => cls === "hidden", toggle: () => {} },
        closest: (selector) => (selector === "[data-chat-workspace-disclosure]" ? details : null)
      };
      const { controller } = makeController({
        element: {
          querySelectorAll: (selector) => (
            selector === "[data-chat-capability-stopped-only]" ? [ reopenForm ] : []
          )
        }
      });

      controller.updateCapabilityActions("stopped");

      if (!attributes.some((attr) => attr.name === "open")) {
        throw new Error("Expected a revealed stopped-only action to open its <details> disclosure");
      }
    }

    // ...but a capability that hides the action must not yank the disclosure
    // open, or an unrelated capability broadcast would expand the header.
    function testHiddenCapabilityActionLeavesDisclosureAlone() {
      const attributes = [];
      const details = { setAttribute: (name, value) => attributes.push({ name, value }) };
      const cloneForm = {
        classList: { contains: () => false, toggle: () => {} },
        closest: (selector) => (selector === "[data-chat-workspace-disclosure]" ? details : null)
      };
      const { controller } = makeController({
        element: {
          querySelectorAll: (selector) => (
            selector === "[data-chat-capability-ready-only]" ? [ cloneForm ] : []
          )
        }
      });

      controller.updateCapabilityActions("stopped");

      if (attributes.length !== 0) {
        throw new Error("Expected a hidden ready-only action to leave its <details> untouched");
      }
    }

    // Snapshot broadcasts re-send the current capability. Reopening the
    // disclosure on every same-state payload would fight a user who
    // intentionally collapsed Workspace, so an action that was already visible
    // must leave its <details> disclosure untouched.
    function testSameStateBroadcastLeavesDisclosureAlone() {
      const attributes = [];
      const details = { setAttribute: (name, value) => attributes.push({ name, value }) };
      const alreadyVisibleForm = {
        classList: { contains: () => false, toggle: () => {} },
        closest: (selector) => (selector === "[data-chat-workspace-disclosure]" ? details : null)
      };
      const { controller } = makeController({
        element: {
          querySelectorAll: (selector) => (
            selector === "[data-chat-capability-stopped-only]" ? [ alreadyVisibleForm ] : []
          )
        }
      });

      controller.updateCapabilityActions("stopped");

      if (attributes.length !== 0) {
        throw new Error("Expected a same-state broadcast to leave the disclosure untouched when the action was already visible");
      }
    }

    function testChatSettingsAutosaveReportsResult() {
      const { controller } = makeController();
      const status = { textContent: "" };
      let submissions = 0;
      const form = {
        querySelector: () => status,
        requestSubmit: () => { submissions += 1; }
      };

      controller.saveSettings({ currentTarget: form });
      if (submissions !== 1 || status.textContent !== "Saving…") {
        throw new Error("Changing chat settings should submit and show progress");
      }

      controller.settingsSubmitted({ currentTarget: form, detail: { success: false } });
      if (status.textContent !== "Could not save chat settings") {
        throw new Error("Failed chat settings save should show an error");
      }

      controller.settingsSubmitted({ currentTarget: form, detail: { success: true } });
      if (status.textContent !== "Chat settings saved") {
        throw new Error("Successful chat settings save should show confirmation");
      }
    }

    // @spec CHAT-API-022 — A dropped connection mid-turn must not leave the
    // in-flight bubble stranded just because it already streamed text: the
    // server never persisted that text (no message_created ever arrived to
    // replace it), so it is stale and must be torn down on disconnect (#4225).
    function testDisconnectMidStreamRemovesOrphanedBubbleWithContent() {
      const wrapper = { removed: false, remove() { this.removed = true; } };
      const bubble = {
        dataset: { streamMessageId: "stream-1" },
        closest: (selector) => (selector === "div" ? wrapper : null)
      };
      const { controller } = makeController({
        streaming: true,
        currentStreamId: "stream-1",
        messagesTarget: {
          querySelector: (selector) => (selector === 'article[data-stream-message-id="stream-1"]' ? bubble : null),
          querySelectorAll: () => [],
          append: () => {}
        },
        toggleTyping: () => {},
        dispatchChatState: () => {},
        setStatus: () => {}
      });

      controller.handleDisconnected();

      if (!wrapper.removed) {
        throw new Error("Expected a disconnect mid-stream to remove the orphaned bubble even though it already streamed content");
      }
      if (controller.streaming) {
        throw new Error("Expected streaming to be reset to false after a disconnect");
      }
    }

    // Mirrors the disconnect case for a provider error mid-stream: handleError
    // must remove the bubble unconditionally, not just when it is still empty.
    function testErrorMidStreamRemovesOrphanedBubbleWithContent() {
      const wrapper = { removed: false, remove() { this.removed = true; } };
      const bubble = {
        dataset: { streamMessageId: "stream-1" },
        closest: (selector) => (selector === "div" ? wrapper : null)
      };
      const { controller } = makeController({
        currentStreamId: "stream-1",
        pendingContent: null,
        messagesTarget: {
          querySelector: (selector) => (selector === 'article[data-stream-message-id="stream-1"]' ? bubble : null),
          querySelectorAll: () => [],
          append: () => {}
        },
        setBusy: () => {},
        toggleTyping: () => {},
        setStatus: () => {}
      });

      controller.handleError({ message_id: "stream-1", message: "Provider unavailable" });

      if (!wrapper.removed) {
        throw new Error("Expected a provider error mid-stream to remove the orphaned bubble even though it already streamed content");
      }
    }

    // A write-tool confirmation pause is a terminal path too (the turn stops
    // to await approval) and must tear down any bubble that streamed
    // reasoning/narration text before the pause, same as message_complete
    // and error.
    function testToolConfirmationRemovesOrphanedBubbleWithContent() {
      const wrapper = { removed: false, remove() { this.removed = true; } };
      const bubble = {
        dataset: { streamMessageId: "stream-1" },
        closest: (selector) => (selector === "div" ? wrapper : null)
      };
      const { controller } = makeController({
        currentStreamId: "stream-1",
        messagesTarget: {
          querySelector: (selector) => (selector === 'article[data-stream-message-id="stream-1"]' ? bubble : null),
          querySelectorAll: () => [],
          append: () => {}
        },
        setBusy: () => {},
        toggleTyping: () => {},
        setStatus: () => {},
        scrollToBottom: () => {}
      });

      controller.handleMessageToolConfirmation({ stream_message_id: "stream-1", tool_name: "trigger_agent_run" });

      if (!wrapper.removed) {
        throw new Error("Expected a tool-confirmation pause to remove an orphaned bubble that streamed narration text");
      }
    }

    // @spec CHAT-SCROLL-001 — A non-persisted streaming bubble at the
    // transcript tail must never become the "Jump to latest" anchor: it can
    // vanish (error, disconnect) or get rewritten (final markdown render)
    // under the user. The anchor must fall back to the last persisted
    // assistant response instead (#4225).
    function testAnchorSelectionExcludesTrailingStreamingBubble() {
      const persistedAnchor = { dataset: {} };
      const streamingBubble = { dataset: { streamMessageId: "stream-1" } };
      const { controller } = makeController({
        messagesTarget: {
          querySelectorAll: (selector) => (
            selector.includes(":not([data-stream-message-id])") ? [ persistedAnchor ] : [ persistedAnchor, streamingBubble ]
          ),
          append: () => {}
        }
      });

      const anchor = controller.lastAssistantTextResponse();

      if (anchor !== persistedAnchor) {
        throw new Error("Expected lastAssistantTextResponse to skip the trailing streaming bubble and return the persisted anchor");
      }
    }

    // @spec CHAT-SCROLL-001 — With no persisted assistant response yet (only
    // a live streaming bubble), the anchor must fall back to null rather than
    // ever returning the bubble.
    function testAnchorSelectionReturnsNullWithOnlyAStreamingBubble() {
      const { controller } = makeController({
        messagesTarget: {
          querySelectorAll: (selector) => (selector.includes(":not([data-stream-message-id])") ? [] : [ { dataset: { streamMessageId: "stream-1" } } ]),
          append: () => {}
        }
      });

      const anchor = controller.lastAssistantTextResponse();

      if (anchor !== null) {
        throw new Error("Expected lastAssistantTextResponse to return null when only a streaming bubble exists");
      }
    }

    // @spec CHAT-API-022 — Reconnecting mid-turn must trigger a resync so any
    // broadcast lost during the gap (message_created / message_complete /
    // error) is recovered; a stable initial connect must not. ActionCable
    // always runs disconnected() before the reconnect's connected() fires, and
    // disconnected() already resets `streaming` to false — so this exercises
    // the real disconnect-then-reconnect sequence (not just handleConnected()
    // in isolation) to prove the "turn was in flight" signal survives that
    // reset instead of being read back as false.
    function testHandleConnectedTriggersResyncWhenResumingATurn() {
      let resyncCalls = 0;
      const { controller } = makeController({
        streaming: true,
        toggleTyping: () => {},
        dispatchChatState: () => {},
        setStatus: () => {},
        resyncTranscript: () => { resyncCalls += 1; }
      });

      controller.handleDisconnected();
      controller.handleConnected();

      if (resyncCalls !== 1) {
        throw new Error(`Expected handleConnected to resync exactly once when resuming a turn, got ${resyncCalls}`);
      }
    }

    function testHandleConnectedSkipsResyncOnStableConnection() {
      let resyncCalls = 0;
      const { controller } = makeController({
        streaming: false,
        setStatus: () => {},
        resyncTranscript: () => { resyncCalls += 1; }
      });

      controller.handleConnected();

      if (resyncCalls !== 0) {
        throw new Error(`Expected handleConnected not to resync on a stable initial connect, got ${resyncCalls} calls`);
      }
    }

    // @spec CHAT-API-022 — A disconnect that happens while no turn is in
    // flight (the common case: idle between turns, or the very first
    // connect) must not trigger a resync on the next reconnect, since there
    // is nothing lost to recover.
    function testHandleConnectedSkipsResyncAfterIdleDisconnect() {
      let resyncCalls = 0;
      const { controller } = makeController({
        streaming: false,
        setStatus: () => {},
        resyncTranscript: () => { resyncCalls += 1; }
      });

      controller.handleDisconnected();
      controller.handleConnected();

      if (resyncCalls !== 0) {
        throw new Error(`Expected handleConnected not to resync after an idle disconnect, got ${resyncCalls} calls`);
      }
    }

    function immediateThenable(value) {
      return {
        then(onFulfilled) {
          return immediateThenable(onFulfilled(value));
        },
        catch() {
          return this;
        }
      };
    }

    // @spec CHAT-API-022 — resyncTranscript fetches every page persisted
    // after the last message the client actually rendered, and replays each
    // one through the same handleMessageCreated path a live broadcast uses.
    function testResyncTranscriptReplaysMessagesSinceLastRenderedId() {
      const rendered = { dataset: { messageId: "42" } };
      const replayed = [];
      let fetchedSinceId = null;
      const { controller } = makeController({
        messagesTarget: {
          querySelectorAll: (selector) => (selector === "[data-message-id]" ? [ rendered ] : []),
          append: () => {}
        },
        scrollToBottom: () => {},
        fetchRecentMessages: (sinceId) => {
          fetchedSinceId = sinceId;
          return immediateThenable({
            messages: [ { message_id: 43, html: "<article></article>" } ],
            hasMore: false
          });
        },
        handleMessageCreated: (data) => { replayed.push(data); }
      });

      controller.resyncTranscript();

      if (fetchedSinceId !== 42) {
        throw new Error(`Expected resync to fetch messages since the last rendered id (42), got ${fetchedSinceId}`);
      }
      if (replayed.length !== 1 || replayed[0].message_id !== 43) {
        throw new Error(`Expected resync to replay the fetched message through handleMessageCreated, got ${JSON.stringify(replayed)}`);
      }
    }

    // @spec CHAT-API-022 — A reconnect may span more than one bounded server
    // page. Follow each returned cursor so the transcript converges without a
    // manual reload.
    function testResyncTranscriptReplaysEveryPage() {
      const rendered = { dataset: { messageId: "42" } };
      const fetchedCursors = [];
      const replayed = [];
      const pages = {
        42: { messages: [ { message_id: 43, html: "<article></article>" } ], hasMore: true },
        43: { messages: [ { message_id: 44, html: "<article></article>" } ], hasMore: false }
      };
      const { controller } = makeController({
        messagesTarget: {
          querySelectorAll: (selector) => (selector === "[data-message-id]" ? [ rendered ] : []),
          append: () => {}
        },
        scrollToBottom: () => {},
        fetchRecentMessages: (sinceId) => {
          fetchedCursors.push(sinceId);
          return immediateThenable(pages[sinceId]);
        },
        handleMessageCreated: (data) => { replayed.push(data.message_id); }
      });

      controller.resyncTranscript();

      if (JSON.stringify(fetchedCursors) !== JSON.stringify([ 42, 43 ])) {
        throw new Error(`Expected resync to fetch every page, got ${JSON.stringify(fetchedCursors)}`);
      }
      if (JSON.stringify(replayed) !== JSON.stringify([ 43, 44 ])) {
        throw new Error(`Expected resync to replay every page, got ${JSON.stringify(replayed)}`);
      }
    }

    // A gap covering the session's very first message leaves nothing
    // rendered to resync from. Must no-op rather than fetch the whole
    // history unbounded.
    function testResyncTranscriptNoOpsWithNothingRenderedYet() {
      let fetchCalls = 0;
      const { controller } = makeController({
        messagesTarget: {
          querySelectorAll: () => [],
          append: () => {}
        },
        fetchRecentMessages: () => {
          fetchCalls += 1;
          return immediateThenable({ messages: [], hasMore: false });
        }
      });

      controller.resyncTranscript();

      if (fetchCalls !== 0) {
        throw new Error("Expected resyncTranscript to no-op when nothing has been rendered yet");
      }
    }

    // @spec CHAT-API-022 — A mid-stream disconnect clears currentStreamId,
    // but the turn can still be in flight server-side: ProcessMessageJob only
    // broadcasts message_start once, so reconnecting resumes chunks for the
    // same stream id with nothing to re-arm tracking. ensureAssistantMessage
    // recreates the bubble either way, so a chunk for an untracked stream id
    // must re-arm currentStreamId/streaming — otherwise a later error/pause/
    // tool-only completion bails out of removePendingAssistantMessage and the
    // recreated bubble is orphaned (#4225).
    function testMessageChunkRearmsTrackingForAnUntrackedStream() {
      const bubble = { streamMessageId: "stream-1" };
      const { controller } = makeController({
        streaming: false,
        currentStreamId: null,
        scrollToBottom: () => {},
        ensureAssistantMessage: () => bubble
      });

      controller.handleMessageChunk({ message_id: "stream-1", content: "partial" });

      if (controller.currentStreamId !== "stream-1") {
        throw new Error(`Expected currentStreamId to re-arm to 'stream-1', got '${controller.currentStreamId}'`);
      }
      if (!controller.streaming) {
        throw new Error("Expected streaming to re-arm to true for an untracked chunk");
      }
    }

    // The ordinary path (message_start already armed tracking) must not be
    // disturbed by this guard — a chunk for the already-tracked stream is a
    // no-op on currentStreamId/streaming.
    function testMessageChunkForTheTrackedStreamLeavesTrackingUnchanged() {
      let streamingWrites = 0;
      const bubble = { streamMessageId: "stream-1" };
      const { controller } = makeController({
        currentStreamId: "stream-1",
        scrollToBottom: () => {},
        ensureAssistantMessage: () => bubble
      });
      Object.defineProperty(controller, "streaming", {
        get() { return true; },
        set() { streamingWrites += 1; }
      });

      controller.handleMessageChunk({ message_id: "stream-1", content: "more" });

      if (controller.currentStreamId !== "stream-1") {
        throw new Error(`Expected currentStreamId to remain 'stream-1', got '${controller.currentStreamId}'`);
      }
      if (streamingWrites !== 0) {
        throw new Error(`Expected no redundant write to streaming for an already-tracked stream, got ${streamingWrites}`);
      }
    }

    // @spec CHAT-API-022 — After reconnecting, a user can start stream B while
    // stream A still emits server-side. Late A events must not take ownership
    // from B or terminate B's in-flight UI.
    function testLateStreamEventsDoNotReplaceOrTerminateTheActiveStream() {
      const appendedContent = [];
      let removedBubbles = 0;
      const { controller } = makeController({
        currentStreamId: "stream-a",
        ensureAssistantMessage: () => {
          throw new Error("Expected a late chunk for stream A not to render a bubble");
        },
        removePendingAssistantMessage: () => { removedBubbles += 1; },
        resyncTranscript: () => {},
        scrollToBottom: () => {},
        toggleTyping: () => {},
        dispatchChatState: () => {},
        setBusy: () => {},
        incrementTokenUsage: () => {}
      });

      controller.handleDisconnected();
      controller.handleConnected();
      controller.handleMessageStart({ message_id: "stream-b", model: "assistant" });
      controller.handleMessageChunk({ message_id: "stream-a", content: "late A" });
      controller.handleMessageComplete({ message_id: "stream-a" });

      if (controller.currentStreamId !== "stream-b" || !controller.streaming) {
        throw new Error("Expected late stream A events to leave stream B active");
      }
      if (removedBubbles !== 1) {
        throw new Error(`Expected only disconnect cleanup to remove a bubble, got ${removedBubbles}`);
      }

      controller.ensureAssistantMessage = () => ({});
      controller.messageControllerFor = () => ({ appendContent: (content) => appendedContent.push(content) });
      controller.handleMessageChunk({ message_id: "stream-b", content: "B continues" });
      controller.handleMessageComplete({ message_id: "stream-b" });

      if (appendedContent.join("") !== "B continues") {
        throw new Error(`Expected stream B to keep receiving chunks, got ${appendedContent.join("")}`);
      }
      if (controller.currentStreamId !== null || controller.streaming) {
        throw new Error("Expected stream B's matching completion to release the streaming state");
      }
      if (removedBubbles !== 2) {
        throw new Error(`Expected stream B completion to remove its own bubble, got ${removedBubbles}`);
      }
    }

    function testLastRenderedMessageIdReturnsHighestId() {
      const { controller } = makeController({
        messagesTarget: {
          querySelectorAll: (selector) => (selector === "[data-message-id]" ? [
            { dataset: { messageId: "10" } },
            { dataset: { messageId: "37" } },
            { dataset: { messageId: "22" } }
          ] : []),
          append: () => {}
        }
      });

      const id = controller.lastRenderedMessageId();

      if (id !== 37) {
        throw new Error(`Expected the highest rendered message id (37), got ${id}`);
      }
    }

    function run() {
      testChatSettingsAutosaveReportsResult();
      testToolCallAppendsCardAndUpdatesStatus();
      testToolCallWithUnknownToolName();
      testToolCallWithMissingHtmlDoesNotAppend();
      testToolResultAppendsCard();
      testToolResultWithMissingHtmlDoesNotAppend();
      testMessageCompleteResetsStreamingState();
      testSendMessageTracksPendingContentForRestoration();
      testHandleErrorRestoresPendingContentIntoInput();
      testHandleErrorNoOpsWithoutPendingContent();
      testHandleErrorDoesNotRestoreWithoutLimitType();
      testMessageCompleteClearsPendingContent();
      testToolConfirmationClearsPendingContent();
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
      testScrollToLatestResponseSmoothScrollsToAnchor();
      testScrollToLatestResponseFallsBackToBottom();
      testJumpToLatestResponseOnLoadSetsScrollTopInstantly();
      testConnectDefersInitialJumpUntilAfterChildControllersRender();
      testDisconnectRemembersTranscriptScrollPosition();
      testJumpToLatestResponseOnLoadRestoresTranscriptPosition();
      testJumpToLatestResponseOnLoadFallsBackWhenTranscriptPositionIsMissing();
      testJumpToLatestResponseOnLoadFallsBackToBottom();
      testJumpToLatestResponseOnLoadUpdatesStickyControl();
      testHandleScrollShowsBackToTopWhenScrolled();
      testHandleScrollHidesBackToTopAtTop();
      testHandleScrollShowsStickyJumpToLatestWhenAnchorAboveViewport();
      testHandleScrollHidesStickyJumpToLatestWhenAnchorInView();
      testHandleScrollStickyJumpToLatestFallsBackToBottomDistance();
      testUpdateViewportHeightTracksPanelOffset();
      testUpdateViewportHeightClampsNegativeOffset();
      testUpdateViewportHeightIsScrollInvariant();
      testStoppedCapabilityUnfoldsItsDisclosure();
      testHiddenCapabilityActionLeavesDisclosureAlone();
      testSameStateBroadcastLeavesDisclosureAlone();
      testDisconnectMidStreamRemovesOrphanedBubbleWithContent();
      testErrorMidStreamRemovesOrphanedBubbleWithContent();
      testToolConfirmationRemovesOrphanedBubbleWithContent();
      testAnchorSelectionExcludesTrailingStreamingBubble();
      testAnchorSelectionReturnsNullWithOnlyAStreamingBubble();
      testHandleConnectedTriggersResyncWhenResumingATurn();
      testHandleConnectedSkipsResyncOnStableConnection();
      testHandleConnectedSkipsResyncAfterIdleDisconnect();
      testResyncTranscriptReplaysMessagesSinceLastRenderedId();
      testResyncTranscriptReplaysEveryPage();
      testResyncTranscriptNoOpsWithNothingRenderedYet();
      testMessageChunkRearmsTrackingForAnUntrackedStream();
      testMessageChunkForTheTrackedStreamLeavesTrackingUnchanged();
      testLateStreamEventsDoNotReplaceOrTerminateTheActiveStream();
      testLastRenderedMessageIdReturnsHighestId();
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
