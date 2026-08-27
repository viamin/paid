# frozen_string_literal: true

require "open3"
require "rails_helper"

class RunnerFormControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    global.document = {
      querySelector() {
        return null;
      }
    };

    const source = fs.readFileSync("app/javascript/controllers/runner_form_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class RunnerFormController extends Controller {");

    const RunnerFormController = new Function("Option", transformed)(function Option(text, value) {
      this.text = text;
      this.value = value;
    });

    function buildSelect({ runnerKey, optionsByServiceType, currentServiceType = "", value = "" }) {
      const options = [];

      return {
        dataset: {
          runnerKey,
          currentServiceType,
          modelOptionsByServiceType: JSON.stringify(optionsByServiceType)
        },
        options,
        value,
        disabled: false,
        add(option) {
          options.push(option);
        }
      };
    }

    function buildApiKeyOption(value, serviceType, selected = false) {
      return {
        value,
        selected,
        hidden: false,
        dataset: { apiServiceType: serviceType }
      };
    }

    function buildController() {
      const controller = Object.create(RunnerFormController.prototype);
      const apiKeyOptions = [
        { value: "", selected: false, hidden: false, dataset: {} },
        buildApiKeyOption("1", "openrouter"),
        buildApiKeyOption("2", "anthropic")
      ];
      const apiKeySelect = {
        value: "1",
        selectedOptions: [apiKeyOptions[1]]
      };
      apiKeyOptions[1].selected = true;

      const modelSelect = buildSelect({
        runnerKey: "opencode",
        optionsByServiceType: {
          openrouter: [["Kimi K2", "moonshotai/kimi-k2-0905"]],
          anthropic: [["Claude Sonnet 4", "claude-sonnet-4-20250514"]]
        }
      });

      controller.authTypeValue = "api_key";
      controller.hasApiKeySelectTarget = true;
      controller.apiKeySelectTarget = apiKeySelect;
      controller.apiKeyOptionTargets = apiKeyOptions;
      controller.dynamicModelSelectTargets = [modelSelect];
      controller.runnerSelectTargets = [{ disabled: false, value: "opencode" }];
      controller.subscriptionFieldsTargets = [];
      controller.apiKeyFieldsTargets = [];
      controller.apiKeySelectContainerTargets = [];
      controller.fallbackRoleFieldTargets = [];
      controller.opencodeSettingsTargets = [];
      controller.kilocodeSettingsTargets = [];
      controller.piSettingsTargets = [];
      controller.ompSettingsTargets = [];
      controller.tierSettingsTargets = [];
      controller.tierSelectTargets = [];
      controller.element = {
        querySelector() {
          return null;
        }
      };

      return { controller, apiKeyOptions, apiKeySelect, modelSelect };
    }

    function selectedOption(apiKeyOptions, value) {
      return apiKeyOptions.find((option) => option.value === value);
    }

    function runHarness() {
      const harness = buildController();

      harness.controller.refreshApiKeyOptions("opencode");

      if (harness.apiKeyOptions[1].hidden || harness.apiKeyOptions[2].hidden) {
        throw new Error("Expected dynamic direct-outbound runners to keep all compatible API keys visible");
      }

      harness.controller.refreshDynamicModelOptions("opencode");

      if (harness.modelSelect.options[1]?.value !== "moonshotai/kimi-k2-0905") {
        throw new Error(`Expected openrouter key to render openrouter models, saw ${harness.modelSelect.options.map((option) => option.value).join(",")}`);
      }

      if (harness.modelSelect.options.some((option) => option.value === "claude-sonnet-4-20250514")) {
        throw new Error("Expected openrouter key to exclude anthropic models");
      }

      harness.apiKeyOptions.forEach((option) => {
        option.selected = false;
      });
      harness.apiKeyOptions[2].selected = true;
      harness.apiKeySelect.value = "2";
      harness.apiKeySelect.selectedOptions = [selectedOption(harness.apiKeyOptions, "2")];

      harness.controller.refreshDynamicModelOptions("opencode");

      if (harness.controller.requiredApiServiceTypeFor("opencode") !== "anthropic") {
        throw new Error(`Expected requiredApiServiceTypeFor() to read the selected key's service type, saw ${harness.controller.requiredApiServiceTypeFor("opencode")}`);
      }

      if (harness.modelSelect.options[1]?.value !== "claude-sonnet-4-20250514") {
        throw new Error(`Expected anthropic key to render anthropic models, saw ${harness.modelSelect.options.map((option) => option.value).join(",")}`);
      }

      if (harness.modelSelect.options.some((option) => option.value === "moonshotai/kimi-k2-0905")) {
        throw new Error("Expected anthropic key change to clear openrouter-only models");
      }
    }

    try {
      runHarness();
    } catch (error) {
      console.error(error.message || error);
      process.exit(1);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe RunnerFormControllerNodeHarness, :no_db do
  # @spec DIRECT-OUTBOUND-CATALOG-007
  it "refreshes direct-outbound model options from the selected API key service type" do
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
