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

    function buildSelect({ runnerKey, optionsByServiceType, currentServiceType = "", value = "", optionalModel = false }) {
      const options = [];

      return {
        dataset: {
          runnerKey,
          optionalModel: optionalModel ? "true" : "false",
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

      const opencodeModelSelect = buildSelect({
        runnerKey: "opencode",
        optionsByServiceType: {
          openrouter: [["Kimi K2", "moonshotai/kimi-k2-0905"]],
          anthropic: [["Claude Sonnet 4", "claude-sonnet-4-20250514"]]
        }
      });
      const piModelSelect = buildSelect({
        runnerKey: "pi",
        currentServiceType: "openrouter",
        optionalModel: true,
        optionsByServiceType: {
          openrouter: [["Kimi K2", "moonshotai/kimi-k2-0905"]],
          anthropic: [["Claude Sonnet 4", "claude-sonnet-4-20250514"]]
        }
      });

      controller.authTypeValue = "api_key";
      controller.hasApiKeySelectTarget = true;
      controller.apiKeySelectTarget = apiKeySelect;
      controller.apiKeyOptionTargets = apiKeyOptions;
      controller.dynamicModelSelectTargets = [opencodeModelSelect, piModelSelect];
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

      return { controller, apiKeyOptions, apiKeySelect, opencodeModelSelect, piModelSelect };
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

      if (harness.opencodeModelSelect.options[1]?.value !== "moonshotai/kimi-k2-0905") {
        throw new Error(`Expected openrouter key to render openrouter models, saw ${harness.opencodeModelSelect.options.map((option) => option.value).join(",")}`);
      }

      if (harness.opencodeModelSelect.options.some((option) => option.value === "claude-sonnet-4-20250514")) {
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

      if (harness.opencodeModelSelect.options[1]?.value !== "claude-sonnet-4-20250514") {
        throw new Error(`Expected anthropic key to render anthropic models, saw ${harness.opencodeModelSelect.options.map((option) => option.value).join(",")}`);
      }

      if (harness.opencodeModelSelect.options.some((option) => option.value === "moonshotai/kimi-k2-0905")) {
        throw new Error("Expected anthropic key change to clear openrouter-only models");
      }

      harness.apiKeyOptions.forEach((option) => {
        option.selected = false;
      });
      harness.apiKeyOptions[1].selected = true;
      harness.apiKeySelect.value = "1";
      harness.apiKeySelect.selectedOptions = [selectedOption(harness.apiKeyOptions, "1")];

      harness.controller.refreshDynamicModelOptions("opencode");

      if (harness.controller.requiredApiServiceTypeFor("opencode") !== "openrouter") {
        throw new Error(`Expected opencode to switch back to the openrouter key before changing runners, saw ${harness.controller.requiredApiServiceTypeFor("opencode")}`);
      }

      harness.controller.runnerSelectTargets[0].value = "pi";
      harness.controller.refreshDynamicModelOptions("pi");

      if (harness.piModelSelect.options[0]?.text !== "Use provider default") {
        throw new Error(`Expected pi placeholder to preserve optional-model copy, saw ${harness.piModelSelect.options[0]?.text}`);
      }

      harness.apiKeyOptions.forEach((option) => {
        option.selected = false;
      });
      harness.apiKeySelect.value = "";
      harness.apiKeySelect.selectedOptions = [selectedOption(harness.apiKeyOptions, "")];
      harness.piModelSelect.dataset.currentServiceType = "";
      harness.controller.runnerSelectTargets[0].value = "pi";

      harness.controller.refreshApiKeyOptions("pi");
      harness.controller.refreshDynamicModelOptions("pi");

      if (harness.controller.requiredApiServiceTypeFor("pi") !== null) {
        throw new Error(`Expected pi to clear stale cached service types after switching runners, saw ${harness.controller.requiredApiServiceTypeFor("pi")}`);
      }

      if (harness.piModelSelect.options[0]?.text !== "Select an API key first") {
        throw new Error(`Expected pi placeholder to prompt for an API key first, saw ${harness.piModelSelect.options[0]?.text}`);
      }

      if (!harness.piModelSelect.disabled) {
        throw new Error("Expected pi model select to stay disabled until a compatible API key is selected");
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
