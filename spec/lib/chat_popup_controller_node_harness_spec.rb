# frozen_string_literal: true

require "open3"
require "rails_helper"

class ChatPopupControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/chat_popup_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class ChatPopupController extends Controller {");

    const ChatPopupController = new Function(transformed)();

    function localStorageWith(values = {}) {
      const entries = new Map(Object.entries(values));

      return {
        getItem(key) {
          return entries.get(key) || null;
        },
        setItem(key, value) {
          entries.set(key, value);
        }
      };
    }

    function renderTargets() {
      const classes = new Set();

      return {
        button: {
          attributes: {},
          setAttribute(name, value) {
            this.attributes[name] = value;
          }
        },
        panel: {
          classList: {
            toggle(name, present) {
              if (present) classes.add(name);
              else classes.delete(name);
            },
            contains(name) {
              return classes.has(name);
            }
          }
        },
        keepOpenButton: {
          attributes: {},
          textContent: "",
          setAttribute(name, value) {
            this.attributes[name] = value;
          }
        }
      };
    }

    // @spec CHAT-API-021
    function runNavigationPersistenceCase() {
      const targets = renderTargets();
      const localStorage = localStorageWith({
        "paid:chat-popup:7": JSON.stringify({ open: true, sessionId: 42, keepOpen: true })
      });
      const controller = Object.create(ChatPopupController.prototype);
      let loadedSession = false;

      global.window = { console: { error() {} }, localStorage };
      controller.accountIdValue = 7;
      controller.buttonTarget = targets.button;
      controller.panelTarget = targets.panel;
      controller.keepOpenButtonTarget = targets.keepOpenButton;
      controller.hasKeepOpenButtonTarget = true;
      controller.loadPanel = () => { loadedSession = true; };

      controller.connect();

      if (controller.state.open !== true || controller.state.sessionId !== 42) {
        throw new Error(`Expected navigation to restore the open popup session, saw ${JSON.stringify(controller.state)}`);
      }

      if (!loadedSession || targets.panel.classList.contains("hidden") || targets.button.attributes["aria-expanded"] !== "true") {
        throw new Error("Expected navigation to reopen and load the persisted chat popup");
      }

      if (targets.keepOpenButton.attributes["aria-pressed"] !== "true" || targets.keepOpenButton.textContent !== "Chat Stays Open") {
        throw new Error("Expected the keep-open control to reflect the persisted preference");
      }

      controller.toggleKeepOpen();
      const disabledPreference = JSON.parse(localStorage.getItem("paid:chat-popup:7"));

      if (disabledPreference.keepOpen !== false || disabledPreference.open !== true) {
        throw new Error(`Expected disabling keep-open to persist the preference without closing the popup, saw ${JSON.stringify(disabledPreference)}`);
      }

      const nextPageTargets = renderTargets();
      const nextPageController = Object.create(ChatPopupController.prototype);
      let reopenedAfterDisabling = false;

      nextPageController.accountIdValue = 7;
      nextPageController.buttonTarget = nextPageTargets.button;
      nextPageController.panelTarget = nextPageTargets.panel;
      nextPageController.loadPanel = () => { reopenedAfterDisabling = true; };
      nextPageController.connect();

      if (nextPageController.state.open !== false || reopenedAfterDisabling || !nextPageTargets.panel.classList.contains("hidden")) {
        throw new Error("Expected a navigation after disabling keep-open to leave the popup closed");
      }

      controller.toggleKeepOpen();

      controller.close();
      const persisted = JSON.parse(localStorage.getItem("paid:chat-popup:7"));

      if (persisted.open !== false || persisted.sessionId !== 42 || persisted.keepOpen !== true) {
        throw new Error(`Expected explicit dismissal to persist a closed popup without losing its session, saw ${JSON.stringify(persisted)}`);
      }

      if (!targets.panel.classList.contains("hidden") || targets.button.attributes["aria-expanded"] !== "false") {
        throw new Error("Expected explicit dismissal to hide the popup");
      }
    }

    // @spec CHAT-API-025
    function runChatNavigationCase() {
      const localStorage = localStorageWith();
      const controller = Object.create(ChatPopupController.prototype);
      controller.accountIdValue = 7;
      controller.state = { open: true, sessionId: 42, keepOpen: false };

      global.window = { localStorage };
      controller.navigate({ button: 0, defaultPrevented: false, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false });

      const persisted = JSON.parse(localStorage.getItem("paid:chat-popup:7"));
      if (persisted.open !== true || persisted.keepOpen !== true || persisted.sessionId !== 42) {
        throw new Error(`Expected chat navigation to preserve the open session, saw ${JSON.stringify(persisted)}`);
      }
    }

    async function runNewChatSuccessCase() {
      const writes = [];
      const fetchCalls = [];
      const contentTarget = { innerHTML: "" };
      const controller = Object.create(ChatPopupController.prototype);

      controller.contentTarget = contentTarget;
      controller.state = { open: true, sessionId: 11 };
      controller.loading = false;
      controller.loadingMarkup = () => "loading";
      controller.errorMarkup = () => "error";
      controller.writeState = () => writes.push({ ...controller.state });
      controller.createSession = async () => 42;
      controller.renderPanel = async (sessionId) => {
        fetchCalls.push(sessionId);
        contentTarget.innerHTML = `panel-${sessionId}`;
      };

      await controller.newChat({ preventDefault() {} });

      if (controller.state.sessionId !== 42) {
        throw new Error(`Expected newChat() to replace the stored session id, saw ${controller.state.sessionId}`);
      }

      if (writes.length !== 1 || writes[0].sessionId !== 42) {
        throw new Error(`Expected newChat() to persist the new session id once, saw ${JSON.stringify(writes)}`);
      }

      if (fetchCalls.length !== 1 || fetchCalls[0] !== 42) {
        throw new Error(`Expected newChat() to render the new session once, saw ${JSON.stringify(fetchCalls)}`);
      }

      if (contentTarget.innerHTML !== "panel-42") {
        throw new Error(`Expected rendered panel markup for the new session, saw ${contentTarget.innerHTML}`);
      }

      if (controller.loading !== false) {
        throw new Error("Expected newChat() to clear the loading flag");
      }
    }

    async function runNewChatFailureCase() {
      const writes = [];
      const contentTarget = { innerHTML: "" };
      const controller = Object.create(ChatPopupController.prototype);

      controller.contentTarget = contentTarget;
      controller.state = { open: true, sessionId: 11 };
      controller.loading = false;
      controller.loadingMarkup = () => "loading";
      controller.errorMarkup = () => "error";
      controller.writeState = () => writes.push({ ...controller.state });
      controller.createSession = async () => {
        throw new Error("boom");
      };
      controller.renderPanel = async () => {
        throw new Error("render should not run");
      };

      global.window = {
        console: { error() {} }
      };

      await controller.newChat({ preventDefault() {} });

      if (controller.state.sessionId !== 11) {
        throw new Error(`Expected newChat() failure to preserve the previous session id, saw ${controller.state.sessionId}`);
      }

      if (writes.length !== 1 || writes[0].sessionId !== 11) {
        throw new Error(`Expected failure path to persist the previous session id, saw ${JSON.stringify(writes)}`);
      }

      if (contentTarget.innerHTML !== "error") {
        throw new Error(`Expected failure path to render the error state, saw ${contentTarget.innerHTML}`);
      }

      if (controller.loading !== false) {
        throw new Error("Expected failure path to clear the loading flag");
      }
    }

    async function runArchiveAndNewChatSuccessCase() {
      const writes = [];
      const fetchCalls = [];
      const contentTarget = { innerHTML: "" };
      const controller = Object.create(ChatPopupController.prototype);

      controller.contentTarget = contentTarget;
      controller.state = { open: true, sessionId: 11 };
      controller.loading = false;
      controller.loadingMarkup = () => "loading";
      controller.errorMarkup = () => "error";
      controller.writeState = () => writes.push({ ...controller.state });
      controller.archiveSession = async (sessionId) => {
        if (sessionId !== 11) throw new Error(`Expected archiveSession() to receive 11, saw ${sessionId}`);
      };
      controller.createSession = async () => 42;
      controller.renderPanel = async (sessionId) => {
        fetchCalls.push(sessionId);
        contentTarget.innerHTML = `panel-${sessionId}`;
      };

      await controller.archiveAndNewChat({ preventDefault() {} });

      if (controller.state.sessionId !== 42) {
        throw new Error(`Expected archiveAndNewChat() to replace the stored session id, saw ${controller.state.sessionId}`);
      }

      if (writes.length !== 1 || writes[0].sessionId !== 42) {
        throw new Error(`Expected archiveAndNewChat() to persist the new session id once, saw ${JSON.stringify(writes)}`);
      }

      if (fetchCalls.length !== 1 || fetchCalls[0] !== 42) {
        throw new Error(`Expected archiveAndNewChat() to render the new session once, saw ${JSON.stringify(fetchCalls)}`);
      }

      if (contentTarget.innerHTML !== "panel-42") {
        throw new Error(`Expected rendered panel markup for the new session, saw ${contentTarget.innerHTML}`);
      }

      if (controller.loading !== false) {
        throw new Error("Expected archiveAndNewChat() to clear the loading flag");
      }
    }

    async function runArchiveAndNewChatCreateFailureCase() {
      const writes = [];
      const contentTarget = { innerHTML: "" };
      const controller = Object.create(ChatPopupController.prototype);

      controller.contentTarget = contentTarget;
      controller.state = { open: true, sessionId: 11 };
      controller.loading = false;
      controller.loadingMarkup = () => "loading";
      controller.errorMarkup = () => "error";
      controller.writeState = () => writes.push({ ...controller.state });
      controller.archiveSession = async () => {};
      controller.createSession = async () => {
        throw new Error("boom");
      };
      controller.renderPanel = async () => {
        throw new Error("render should not run");
      };

      global.window = {
        console: { error() {} }
      };

      await controller.archiveAndNewChat({ preventDefault() {} });

      if (controller.state.sessionId !== null) {
        throw new Error(`Expected create failure after archive to clear the stored session id, saw ${controller.state.sessionId}`);
      }

      if (writes.length !== 1 || writes[0].sessionId !== null) {
        throw new Error(`Expected failure path to persist a cleared session id, saw ${JSON.stringify(writes)}`);
      }

      if (contentTarget.innerHTML !== "error") {
        throw new Error(`Expected failure path to render the error state, saw ${contentTarget.innerHTML}`);
      }

      if (controller.loading !== false) {
        throw new Error("Expected failure path to clear the loading flag");
      }
    }

    async function run() {
      global.window = {
        console: { error() {} }
      };

      if (process.argv[1] === "navigation") {
        runNavigationPersistenceCase();
    runChatNavigationCase();
        return;
      }

      await runNewChatSuccessCase();
      await runNewChatFailureCase();
      await runArchiveAndNewChatSuccessCase();
      await runArchiveAndNewChatCreateFailureCase();
    }

    run().catch((error) => {
      console.error(error);
      process.exit(1);
    });
  JAVASCRIPT

  def self.run(scenario = "sessions")
    Open3.capture3("node", "-e", SCRIPT, scenario, chdir: Rails.root.to_s)
  end
end

RSpec.describe ChatPopupControllerNodeHarness, :no_db do
  # @spec CHAT-API-021
  it "restores popup state and session after navigation, then honors dismissal" do
    stdout, stderr, status = described_class.run("navigation")

    expect(status.success?).to be(true), <<~MESSAGE
      Node regression harness failed.
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
  end

  it "replaces popup state only after a fresh session is created" do
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
