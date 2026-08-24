# frozen_string_literal: true

require "open3"
require "rails_helper"

class TestAllControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/test_all_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class TestAllController extends Controller {");

    const TestAllController = new Function(transformed)();

    async function run() {
      let resolveFirst;
      let rejectSecond;
      let resolveThird;

      const firstPromise = new Promise((resolve) => { resolveFirst = resolve; });
      const secondPromise = new Promise((_, reject) => { rejectSecond = reject; });
      const thirdPromise = new Promise((resolve) => { resolveThird = resolve; });

      const firstRow = { id: "runner-1" };
      const secondRow = { id: "runner-2" };
      const thirdRow = { id: "runner-3" };
      const buttonTarget = { disabled: false, textContent: "Test All" };
      const testCalls = [];

      const controller = Object.create(TestAllController.prototype);
      controller.buttonTarget = buttonTarget;
      controller.hasButtonTarget = true;
      controller.runnerTargets = [firstRow, secondRow, thirdRow];
      controller.element = { isConnected: true };
      controller.application = {
        getControllerForElementAndIdentifier(element, identifier) {
          if (identifier !== "test-agent") throw new Error(`Unexpected identifier: ${identifier}`);

          if (element === firstRow) {
            return {
              test() {
                testCalls.push("runner-1");
                return firstPromise;
              }
            };
          }

          if (element === secondRow) {
            return {
              test() {
                testCalls.push("runner-2");
                return secondPromise;
              }
            };
          }

          if (element === thirdRow) {
            return {
              test() {
                testCalls.push("runner-3");
                return thirdPromise;
              }
            };
          }

          return null;
        }
      };

      controller.connect();

      if (buttonTarget.textContent !== "Test All") {
        throw new Error(`Expected idle label to remain Test All, got: ${buttonTarget.textContent}`);
      }

      const batchPromise = controller.testAll({ preventDefault() {} });

      if (!buttonTarget.disabled) {
        throw new Error("Expected Test All button to disable immediately");
      }

      if (buttonTarget.textContent !== "Testing... 0/3") {
        throw new Error(`Expected initial progress label, got: ${buttonTarget.textContent}`);
      }

      resolveFirst();
      await Promise.resolve();
      await Promise.resolve();

      if (buttonTarget.textContent !== "Testing... 1/3") {
        throw new Error(`Expected progress label after first completion, got: ${buttonTarget.textContent}`);
      }

      rejectSecond(new Error("runner cooldown"));
      await Promise.resolve();
      await Promise.resolve();

      if (buttonTarget.textContent !== "Testing... 2/3") {
        throw new Error(`Expected progress label after a rejected runner, got: ${buttonTarget.textContent}`);
      }

      resolveThird();
      await batchPromise;

      if (buttonTarget.disabled) {
        throw new Error("Expected Test All button to re-enable after completion");
      }

      if (buttonTarget.textContent !== "Tested 3/3") {
        throw new Error(`Expected completion label, got: ${buttonTarget.textContent}`);
      }

      if (testCalls.join(",") !== "runner-1,runner-2,runner-3") {
        throw new Error(`Expected both runner controllers to be invoked, got: ${testCalls.join(",")}`);
      }
    }

    run().catch((error) => {
      console.error(error.message || error);
      process.exit(1);
    });
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe TestAllControllerNodeHarness, :no_db do
  # @spec RUNNERS-INDEX-010
  it "runs each row test through the existing controller while reporting batch progress" do
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
