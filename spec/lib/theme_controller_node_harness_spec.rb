# frozen_string_literal: true

require "open3"
require "rails_helper"

class ThemeControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/theme_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class ThemeController extends Controller {");

    const ThemeController = new Function(transformed)();

    function iconNode() {
      const node = { hidden: false };
      node.classList = {
        toggle(_name, force) {
          node.hidden = force;
        }
      };

      return node;
    }

    function iconButton() {
      const attributes = {};
      const icons = {
        sun: iconNode(),
        moon: iconNode(),
        system: iconNode()
      };

      return {
        attributes,
        setAttribute(name, value) {
          attributes[name] = value;
        },
        querySelector(selector) {
          const match = selector.match(/\\[data-theme-icon=(.+)\\]/);
          return match ? icons[match[1]] : null;
        },
        icons
      };
    }

    const button = iconButton();
    const localStorageState = {
      theme_preference: "dark"
    };

    global.window = {
      matchMedia: () => ({
        matches: false,
        addEventListener() {},
        removeEventListener() {}
      }),
      localStorage: {
        getItem(key) { return localStorageState[key] ?? null; },
        setItem(key, value) { localStorageState[key] = value; }
      }
    };

    global.document = {
      documentElement: {
        classList: { toggle() {} },
        dataset: {}
      },
      querySelector() { return null; }
    };

    let persistedCalls = 0;
    const controller = Object.create(ThemeController.prototype);
    controller.signedInValue = true;
    controller.hasIconTarget = true;
    controller.iconTargets = [button];
    controller.persistToServer = () => { persistedCalls += 1; };
    controller._preferenceValue = "light";
    Object.defineProperty(controller, "preferenceValue", {
      get() {
        return this._preferenceValue;
      },
      set(value) {
        this._preferenceValue = value;
        this.preferenceValueChanged();
      }
    });

    controller.initialize();
    controller._preferenceValue = "dark";
    controller._lastPersisted = "dark";
    controller.preferenceValueChanged();

    if (persistedCalls !== 0) {
      throw new Error(`Expected no persistence on initial callback, saw ${persistedCalls}`);
    }

    controller._preferenceValue = "light";
    controller._lastPersisted = "light";
    persistedCalls = 0;
    controller.connect();

    if (controller.preferenceValue !== "dark") {
      throw new Error(`Expected connect() to prefer stored theme, saw ${controller.preferenceValue}`);
    }

    if (persistedCalls !== 1) {
      throw new Error(`Expected stored signed-in theme to be re-persisted once, saw ${persistedCalls}`);
    }

    if (button.attributes["aria-label"] !== "Cycle theme (current: Dark)") {
      throw new Error(`Unexpected aria-label: ${button.attributes["aria-label"]}`);
    }

    if (document.documentElement.dataset.themeEffectivePreference !== "dark") {
      throw new Error(`Expected effective preference dataset to be dark, saw ${document.documentElement.dataset.themeEffectivePreference}`);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ThemeControllerNodeHarness, :no_db do
  it "keeps the signed-in theme optimistic and updates accessible labels" do
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
