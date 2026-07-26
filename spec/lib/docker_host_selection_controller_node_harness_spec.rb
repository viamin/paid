# frozen_string_literal: true

require "open3"
require "rails_helper"

class DockerHostSelectionControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    function loadController(path, className) {
      const source = fs.readFileSync(path, "utf8");
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", `return class ${className} extends Controller {`);

      return new Function(transformed)();
    }

    function option(value, label = value) {
      return { value, textContent: label };
    }

    function buildSelect(initialValue) {
      const options = [];
      const dataset = {};
      let currentValue = initialValue;

      return {
        dataset,
        options,
        appendChild(node) {
          options.push(node);
        },
        set innerHTML(_value) {
          options.length = 0;
          currentValue = "";
        },
        get value() {
          return currentValue;
        },
        set value(nextValue) {
          currentValue = String(nextValue);
        }
      };
    }

    global.document = {
      createElement(_tagName) {
        return option("");
      },
      querySelector() {
        return null;
      }
    };

    const GoalToggleController = loadController(
      "app/javascript/controllers/goal_toggle_controller.js",
      "GoalToggleController"
    );
    const RetryDockerHostController = loadController(
      "app/javascript/controllers/retry_docker_host_controller.js",
      "RetryDockerHostController"
    );

    function buildGoalToggle(value) {
      const controller = Object.create(GoalToggleController.prototype);
      controller.dockerHostSelectTarget = buildSelect(value);
      return controller;
    }

    function buildRetry(value, previousSelection) {
      const controller = Object.create(RetryDockerHostController.prototype);
      controller.dockerHostSelectTarget = buildSelect(value);
      if (previousSelection !== undefined) {
        controller.dockerHostSelectTarget.dataset.previousSelection = previousSelection;
      }
      return controller;
    }

    function values(select) {
      return select.options.map((entry) => entry.value);
    }

    const payloadWithInherit = {
      options: [
        ["Inherit saved placement preference", ""],
        ["Preferred Host", "preferred-host"]
      ],
      selected_host_identifier: "preferred-host"
    };

    const payloadWithoutInherit = {
      options: [
        ["Preferred Host", "preferred-host"]
      ],
      selected_host_identifier: "preferred-host"
    };

    const goalToggleInherit = buildGoalToggle("");
    goalToggleInherit.populateDockerHostSelect(payloadWithInherit);

    if (goalToggleInherit.dockerHostSelectTarget.value !== "") {
      throw new Error(`Expected goal toggle inherit selection to stay empty, saw ${goalToggleInherit.dockerHostSelectTarget.value}`);
    }

    if (values(goalToggleInherit.dockerHostSelectTarget).join(",") !== ",preferred-host") {
      throw new Error("Expected goal toggle options to include inherit and preferred host");
    }

    const goalToggleFallback = buildGoalToggle("");
    goalToggleFallback.populateDockerHostSelect(payloadWithoutInherit);

    if (goalToggleFallback.dockerHostSelectTarget.value !== "preferred-host") {
      throw new Error(`Expected goal toggle to fall back when inherit disappears, saw ${goalToggleFallback.dockerHostSelectTarget.value}`);
    }

    const retryInherit = buildRetry("", "");
    retryInherit.populateDockerHostSelect(payloadWithInherit);

    if (retryInherit.dockerHostSelectTarget.value !== "") {
      throw new Error(`Expected retry inherit selection to stay empty, saw ${retryInherit.dockerHostSelectTarget.value}`);
    }

    if (retryInherit.dockerHostSelectTarget.dataset.previousSelection !== "") {
      throw new Error("Expected retry controller to persist the empty inherit selection");
    }

    const retryFallback = buildRetry("", "");
    retryFallback.populateDockerHostSelect(payloadWithoutInherit);

    if (retryFallback.dockerHostSelectTarget.value !== "preferred-host") {
      throw new Error(`Expected retry controller to fall back when inherit disappears, saw ${retryFallback.dockerHostSelectTarget.value}`);
    }

    if (retryFallback.dockerHostSelectTarget.dataset.previousSelection !== "preferred-host") {
      throw new Error("Expected retry controller to remember the fallback host selection");
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe DockerHostSelectionControllerNodeHarness, :no_db do
  it "preserves inherit selections until the server stops offering that option" do
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
