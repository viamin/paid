# frozen_string_literal: true

require "open3"
require "rails_helper"

class TestAgentControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/test_agent_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class TestAgentController extends Controller {");

    const TestAgentController = new Function(transformed)();

    function run() {
      const controller = Object.create(TestAgentController.prototype);
      const message = controller.troubleshootingFor("authentication");
      controller.buttonTarget = { disabled: false, textContent: "" };
      controller.resultTarget = { innerHTML: "" };

      if (message.includes("on this page")) {
        throw new Error(`Expected authentication troubleshooting to avoid page-local setup guidance, got: ${message}`);
      }

      if (!message.includes("Open Edit for this runner")) {
        throw new Error(`Expected authentication troubleshooting to point at the runner edit surface, got: ${message}`);
      }

      if (!message.includes("runner credentials")) {
        throw new Error(`Expected authentication troubleshooting to mention runner credentials, got: ${message}`);
      }

      controller.resetButton();
      if (controller.buttonTarget.textContent !== "Test Runner") {
        throw new Error(`Expected resetButton() to restore Test Runner, got: ${controller.buttonTarget.textContent}`);
      }

      controller.showLoading();
      if (!controller.resultTarget.innerHTML.includes("Testing runner...")) {
        throw new Error(`Expected showLoading() to render Testing runner..., got: ${controller.resultTarget.innerHTML}`);
      }
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

RSpec.describe TestAgentControllerNodeHarness, :no_db do
  # @spec RUNNERS-INDEX-007
  it "keeps Test Runner copy aligned with the remaining runner auth surfaces" do
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
