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

    function buildController({ signedIn, storedPreference, initialPreference }) {
      const button = iconButton();
      const localStorageState = {
        theme_preference: storedPreference
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
        querySelector() { return null; },
        getElementById() { return null; }
      };

      let persistedCalls = 0;
      const controller = Object.create(ThemeController.prototype);
      controller.signedInValue = signedIn;
      controller.hasIconTarget = true;
      controller.iconTargets = [button];
      controller.persistToServer = () => { persistedCalls += 1; };
      controller._preferenceValue = initialPreference;
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
      controller._lastPersisted = initialPreference;

      return { button, controller, localStorageState, persistedCalls: () => persistedCalls };
    }

    const signedInCase = buildController({
      signedIn: true,
      storedPreference: "dark",
      initialPreference: "light"
    });
    signedInCase.controller.connect();

    if (signedInCase.controller.preferenceValue !== "light") {
      throw new Error(`Expected signed-in connect() to keep server theme, saw ${signedInCase.controller.preferenceValue}`);
    }

    if (signedInCase.persistedCalls() !== 0) {
      throw new Error(`Expected no persistence when booting signed-in theme, saw ${signedInCase.persistedCalls()}`);
    }

    if (signedInCase.localStorageState.theme_preference !== "light") {
      throw new Error(`Expected signed-in boot to refresh local storage from server theme, saw ${signedInCase.localStorageState.theme_preference}`);
    }

    if (signedInCase.button.attributes["aria-label"] !== "Cycle theme (current: Light)") {
      throw new Error(`Unexpected signed-in aria-label: ${signedInCase.button.attributes["aria-label"]}`);
    }

    if (document.documentElement.dataset.themeEffectivePreference !== "light") {
      throw new Error(`Expected signed-in effective preference dataset to be light, saw ${document.documentElement.dataset.themeEffectivePreference}`);
    }

    const guestCase = buildController({
      signedIn: false,
      storedPreference: "dark",
      initialPreference: "light"
    });
    guestCase.controller.connect();

    if (guestCase.controller.preferenceValue !== "dark") {
      throw new Error(`Expected guest connect() to prefer stored theme, saw ${guestCase.controller.preferenceValue}`);
    }

    if (guestCase.persistedCalls() !== 0) {
      throw new Error(`Expected no persistence for guest theme changes, saw ${guestCase.persistedCalls()}`);
    }

    if (guestCase.button.attributes["aria-label"] !== "Cycle theme (current: Dark)") {
      throw new Error(`Unexpected guest aria-label: ${guestCase.button.attributes["aria-label"]}`);
    }

    if (document.documentElement.dataset.themeEffectivePreference !== "dark") {
      throw new Error(`Expected guest effective preference dataset to be dark, saw ${document.documentElement.dataset.themeEffectivePreference}`);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ThemeControllerNodeHarness, :no_db do
  it "prefers the server theme for signed-in users and local storage for guests" do
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
