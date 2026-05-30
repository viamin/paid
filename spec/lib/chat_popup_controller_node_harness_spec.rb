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

    async function run() {
      global.window = {
        console: { error() {} }
      };

      await runNewChatSuccessCase();
      await runNewChatFailureCase();
    }

    run().catch((error) => {
      console.error(error);
      process.exit(1);
    });
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ChatPopupControllerNodeHarness, :no_db do
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
