# frozen_string_literal: true

require "open3"
require "rails_helper"

class DisclosureGroupControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/disclosure_group_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class DisclosureGroupController extends Controller {");

    const DisclosureGroupController = new Function(transformed)();

    function buildDisclosure() {
      const listeners = {};

      return {
        open: false,
        listeners,
        addEventListener(name, listener) {
          listeners[name] = listener;
        },
        removeEventListener(name, listener) {
          if (listeners[name] === listener) delete listeners[name];
        },
        contains(node) {
          return node === this;
        }
      };
    }

    function buildController() {
      const documentListeners = {};

      global.document = {
        addEventListener(name, listener) {
          documentListeners[name] = listener;
        },
        removeEventListener(name, listener) {
          if (documentListeners[name] === listener) delete documentListeners[name];
        }
      };

      const controller = Object.create(DisclosureGroupController.prototype);
      const insights = buildDisclosure();
      const operations = buildDisclosure();
      controller.disclosureTargets = [insights, operations];

      return { controller, documentListeners, insights, operations };
    }

    function runHarness() {
      const harness = buildController();
      harness.controller.connect();

      harness.insights.open = true;
      harness.insights.listeners.toggle({ target: harness.insights });

      if (harness.operations.open) {
        throw new Error("Expected opening one disclosure to close its sibling");
      }

      harness.operations.open = true;
      harness.documentListeners.click({ target: harness.operations });

      if (!harness.operations.open) {
        throw new Error("Expected inside clicks to keep the disclosure open");
      }

      harness.documentListeners.click({ target: {} });

      if (harness.operations.open) {
        throw new Error("Expected outside clicks to close the open disclosure");
      }

      harness.insights.open = true;
      harness.documentListeners.keydown({ key: "Escape" });

      if (harness.insights.open) {
        throw new Error("Expected Escape to close the open disclosure");
      }

      harness.insights.open = true;
      harness.documentListeners["turbo:before-visit"]();

      if (harness.insights.open) {
        throw new Error("Expected turbo:before-visit to close the open disclosure");
      }

      harness.controller.disconnect();

      if (Object.keys(harness.documentListeners).length !== 0) {
        throw new Error(`Expected disconnect() to remove document listeners, saw ${Object.keys(harness.documentListeners)}`);
      }

      if (Object.keys(harness.insights.listeners).length !== 0 || Object.keys(harness.operations.listeners).length !== 0) {
        throw new Error("Expected disconnect() to remove toggle listeners from each disclosure");
      }
    }

    runHarness();
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe DisclosureGroupControllerNodeHarness, :no_db do
  it "restores outside-click, Escape, and mutually-exclusive-open behavior for native disclosures" do
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
