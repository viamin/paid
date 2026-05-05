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

    global.window = {
      matchMedia: () => ({
        matches: false,
        addEventListener() {},
        removeEventListener() {}
      }),
      localStorage: {
        getItem() { return null; },
        setItem() {}
      }
    };

    global.document = {
      documentElement: {
        classList: { toggle() {} }
      },
      querySelector() { return null; }
    };

    let persistedCalls = 0;
    const controller = Object.create(ThemeController.prototype);
    controller.preferenceValue = "dark";
    controller.signedInValue = true;
    controller.updateIcons = () => {};
    controller.persistToServer = () => { persistedCalls += 1; };

    controller.initialize();
    controller.preferenceValueChanged();

    if (persistedCalls !== 0) {
      throw new Error(`Expected no persistence on initial callback, saw ${persistedCalls}`);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ThemeControllerNodeHarness, :no_db do
  it "does not persist the signed-in preference during the first value callback" do
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
