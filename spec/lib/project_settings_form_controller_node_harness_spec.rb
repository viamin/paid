# frozen_string_literal: true

require "open3"
require "rails_helper"

class ProjectSettingsFormControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/project_settings_form_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class ProjectSettingsFormController extends Controller {");

    const ProjectSettingsFormController = new Function(transformed)();

    function classList() {
      const values = new Set();
      return {
        contains(value) { return values.has(value); },
        toggle(value, enabled) {
          if (enabled) values.add(value);
          else values.delete(value);
        }
      };
    }

    function field(attribute) {
      const input = { type: "text", disabled: false };
      const hidden = { type: "hidden", disabled: false };
      return {
        dataset: { attribute },
        classList: classList(),
        querySelectorAll() { return [hidden, input]; },
        input,
        hidden
      };
    }

    function buildController() {
      const controller = Object.create(ProjectSettingsFormController.prototype);
      const ownRepo = { checked: true, value: "own_repo" };
      const upstream = { checked: false, value: "upstream" };
      const panel = { classList: classList() };
      const note = { classList: classList() };
      const reviewSettings = field("review_settings");

      controller.hasPrTargetTarget = true;
      controller.prTargetTargets = [ownRepo, upstream];
      controller.hasPrTargetUpstreamPanelTarget = true;
      controller.prTargetUpstreamPanelTarget = panel;
      controller.hasPrTargetUpstreamNoteTarget = true;
      controller.prTargetUpstreamNoteTarget = note;
      controller.prTargetGatedFieldTargets = [reviewSettings];

      return { controller, ownRepo, upstream, panel, note, reviewSettings };
    }

    function runHarness() {
      const harness = buildController();
      harness.controller.applyPrTargetGating();

      if (harness.reviewSettings.input.disabled || harness.reviewSettings.hidden.disabled ||
        harness.reviewSettings.classList.contains("opacity-50")) {
        throw new Error("Expected own-repo mode to leave gated settings enabled");
      }
      if (!harness.panel.classList.contains("hidden") || !harness.note.classList.contains("hidden")) {
        throw new Error("Expected own-repo mode to hide the upstream field and explanation");
      }

      harness.ownRepo.checked = false;
      harness.upstream.checked = true;
      harness.controller.prTargetChanged();

      if (!harness.reviewSettings.input.disabled || !harness.reviewSettings.hidden.disabled ||
        !harness.reviewSettings.classList.contains("opacity-50")) {
        throw new Error("Expected upstream mode to disable and gray gated settings");
      }
      if (harness.panel.classList.contains("hidden") || harness.note.classList.contains("hidden")) {
        throw new Error("Expected upstream mode to show the upstream field and explanation");
      }

      harness.ownRepo.checked = true;
      harness.upstream.checked = false;
      harness.controller.prTargetChanged();

      if (harness.reviewSettings.input.disabled || harness.reviewSettings.hidden.disabled ||
        harness.reviewSettings.classList.contains("opacity-50")) {
        throw new Error("Expected switching back to own-repo mode to restore gated settings");
      }
    }

    runHarness();
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ProjectSettingsFormControllerNodeHarness, :no_db do
  # @spec PR-TARGET-010
  it "toggles upstream-gated settings without losing their values" do
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
