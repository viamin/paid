# frozen_string_literal: true

require "open3"
require "rails_helper"

class DropdownControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/dropdown_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class DropdownController extends Controller {");

    const DropdownController = new Function(transformed)();

    function buildClassList(initial = []) {
      const classes = new Set(initial);

      return {
        add(name) {
          classes.add(name);
        },
        contains(name) {
          return classes.has(name);
        },
        remove(name) {
          classes.delete(name);
        }
      };
    }

    function buildController() {
      const listeners = {};
      const menu = {
        classList: buildClassList()
      };
      const button = {
        attributes: {},
        setAttribute(name, value) {
          this.attributes[name] = value;
        }
      };
      const insideNode = {};

      global.document = {
        addEventListener(name, listener) {
          listeners[name] = listener;
        },
        removeEventListener(name, listener) {
          if (listeners[name] === listener) delete listeners[name];
        }
      };

      const controller = Object.create(DropdownController.prototype);
      controller.menuTarget = menu;
      controller.buttonTarget = button;
      controller.hasMenuTarget = true;
      controller.hasButtonTarget = true;
      controller.element = {
        contains(node) {
          return node === insideNode;
        }
      };

      return { button, controller, insideNode, listeners, menu };
    }

    function runHarness() {
      const harness = buildController();
      harness.controller.connect();

      if (!harness.menu.classList.contains("hidden")) {
        throw new Error("Expected connect() to close the menu");
      }

      if (harness.button.attributes["aria-expanded"] !== "false") {
        throw new Error(`Expected connect() to collapse the button, saw ${harness.button.attributes["aria-expanded"]}`);
      }

      const toggleEvent = {
        prevented: false,
        stopped: false,
        preventDefault() {
          this.prevented = true;
        },
        stopPropagation() {
          this.stopped = true;
        }
      };

      harness.controller.toggle(toggleEvent);

      if (!toggleEvent.prevented || !toggleEvent.stopped) {
        throw new Error("Expected toggle() to stop the triggering click event");
      }

      if (harness.menu.classList.contains("hidden")) {
        throw new Error("Expected toggle() to open the menu");
      }

      if (harness.button.attributes["aria-expanded"] !== "true") {
        throw new Error(`Expected open menu aria-expanded=true, saw ${harness.button.attributes["aria-expanded"]}`);
      }

      harness.listeners.click({ target: harness.insideNode });

      if (harness.menu.classList.contains("hidden")) {
        throw new Error("Expected inside clicks to keep the menu open");
      }

      harness.listeners.click({ target: {} });

      if (!harness.menu.classList.contains("hidden")) {
        throw new Error("Expected outside clicks to close the menu");
      }

      harness.controller.open();
      harness.listeners.keydown({ key: "Escape" });

      if (!harness.menu.classList.contains("hidden")) {
        throw new Error("Expected Escape to close the menu");
      }

      harness.controller.open();
      harness.listeners["turbo:before-visit"]();

      if (!harness.menu.classList.contains("hidden")) {
        throw new Error("Expected turbo:before-visit to close the menu");
      }

      harness.controller.disconnect();

      if (Object.keys(harness.listeners).length !== 0) {
        throw new Error(`Expected disconnect() to remove document listeners, saw ${Object.keys(harness.listeners)}`);
      }
    }

    runHarness();
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe DropdownControllerNodeHarness, :no_db do
  it "opens and closes menus through the shared dropdown controller lifecycle" do
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
