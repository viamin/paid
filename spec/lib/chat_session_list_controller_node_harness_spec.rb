# frozen_string_literal: true

require "open3"
require "rails_helper"

class ChatSessionListControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/chat_session_list_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class ChatSessionListController extends Controller {");

    const ChatSessionListController = new Function(transformed)();

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
        },
        toggle(name, force) {
          if (force === undefined) {
            if (classes.has(name)) {
              classes.delete(name);
            } else {
              classes.add(name);
            }

            return classes.has(name);
          }

          if (force) {
            classes.add(name);
          } else {
            classes.delete(name);
          }

          return force;
        }
      };
    }

    function buildController(mediaQuery) {
      const bodyClassList = buildClassList();
      const menuClassList = buildClassList(["hidden"]);
      const openLabelClassList = buildClassList();
      const closeLabelClassList = buildClassList(["hidden"]);
      const listeners = {};
      let observerDisconnected = false;

      global.window = {
        MutationObserver: class {
          constructor(callback) {
            this.callback = callback;
          }

          observe() {}

          disconnect() {
            observerDisconnected = true;
          }
        },
        location: { pathname: "/chat/42" },
        matchMedia() {
          return mediaQuery;
        }
      };

      global.document = {
        addEventListener(name, listener) {
          listeners[name] = listener;
        },
        body: { classList: bodyClassList },
        removeEventListener(name, listener) {
          if (listeners[name] === listener) delete listeners[name];
        }
      };

      const menu = {
        attributes: {},
        classList: menuClassList,
        setAttribute(name, value) {
          this.attributes[name] = value;
        }
      };

      const button = {
        attributes: {},
        setAttribute(name, value) {
          this.attributes[name] = value;
        }
      };

      const controller = Object.create(ChatSessionListController.prototype);
      controller.cardTargets = [];
      controller.hasActiveSessionIdValue = false;
      controller.hasModalTarget = false;
      controller.hasMobileButtonTarget = true;
      controller.hasMobileCloseLabelTarget = true;
      controller.hasMobileMenuTarget = true;
      controller.hasMobileOpenLabelTarget = true;
      controller.hasSearchInputTarget = false;
      controller.listTarget = {};
      controller.mobileButtonTarget = button;
      controller.mobileCloseLabelTarget = { classList: closeLabelClassList };
      controller.mobileMenuTarget = menu;
      controller.mobileOpenLabelTarget = { classList: openLabelClassList };

      return {
        bodyClassList,
        button,
        closeLabelClassList,
        connect() {
          controller.connect();
        },
        controller,
        listeners,
        menu,
        observerDisconnected: () => observerDisconnected,
        openLabelClassList
      };
    }

    function runModernListenerCase() {
      let changeListener = null;
      const mediaQuery = {
        addEventListener(name, listener) {
          if (name !== "change") throw new Error(`Unexpected event name: ${name}`);
          changeListener = listener;
        },
        matches: false,
        removeEventListener(name, listener) {
          if (name !== "change") throw new Error(`Unexpected removal event name: ${name}`);
          if (changeListener === listener) changeListener = null;
        }
      };

      const harness = buildController(mediaQuery);
      harness.connect();

      if (harness.menu.attributes["aria-hidden"] !== "true") {
        throw new Error(`Expected closed menu aria-hidden=true, saw ${harness.menu.attributes["aria-hidden"]}`);
      }

      if (harness.button.attributes["aria-expanded"] !== "false") {
        throw new Error(`Expected collapsed button aria-expanded=false, saw ${harness.button.attributes["aria-expanded"]}`);
      }

      harness.controller.toggleSidebar();

      if (harness.menu.classList.contains("hidden")) {
        throw new Error("Expected toggleSidebar() to open the mobile menu");
      }

      if (harness.menu.attributes["aria-hidden"] !== "false") {
        throw new Error(`Expected open menu aria-hidden=false, saw ${harness.menu.attributes["aria-hidden"]}`);
      }

      if (!harness.bodyClassList.contains("overflow-hidden")) {
        throw new Error("Expected open menu to lock body scrolling");
      }

      if (!harness.openLabelClassList.contains("hidden")) {
        throw new Error("Expected the open label to hide while the menu is open");
      }

      if (harness.closeLabelClassList.contains("hidden")) {
        throw new Error("Expected the close label to show while the menu is open");
      }

      if (typeof changeListener !== "function") {
        throw new Error("Expected connect() to register a media query listener");
      }

      mediaQuery.matches = true;
      changeListener({ matches: true });

      if (!harness.menu.classList.contains("hidden")) {
        throw new Error("Expected desktop breakpoint transition to close the mobile menu");
      }

      harness.controller.disconnect();

      if (changeListener !== null) {
        throw new Error("Expected disconnect() to unregister the media query listener");
      }

      if (!harness.observerDisconnected()) {
        throw new Error("Expected disconnect() to stop the mutation observer");
      }
    }

    function runLegacyListenerCase() {
      let listener = null;
      const mediaQuery = {
        addListener(callback) {
          listener = callback;
        },
        matches: false,
        removeListener(callback) {
          if (listener === callback) listener = null;
        }
      };

      const harness = buildController(mediaQuery);
      harness.connect();
      harness.controller.toggleSidebar();
      harness.controller.disconnect();

      if (listener !== null) {
        throw new Error("Expected legacy media query listener to be removed on disconnect()");
      }
    }

    function runMissingMatchMediaCase() {
      const bodyClassList = buildClassList();
      const menuClassList = buildClassList(["hidden"]);
      const listeners = {};
      let observerDisconnected = false;

      global.window = {
        MutationObserver: class {
          observe() {}

          disconnect() {
            observerDisconnected = true;
          }
        },
        location: { pathname: "/chat/42" }
      };

      global.document = {
        addEventListener(name, listener) {
          listeners[name] = listener;
        },
        body: { classList: bodyClassList },
        removeEventListener(name, listener) {
          if (listeners[name] === listener) delete listeners[name];
        }
      };

      const controller = Object.create(ChatSessionListController.prototype);
      controller.cardTargets = [];
      controller.hasActiveSessionIdValue = false;
      controller.hasModalTarget = false;
      controller.hasMobileButtonTarget = false;
      controller.hasMobileCloseLabelTarget = false;
      controller.hasMobileMenuTarget = true;
      controller.hasMobileOpenLabelTarget = false;
      controller.hasSearchInputTarget = false;
      controller.listTarget = {};
      controller.mobileMenuTarget = {
        attributes: {},
        classList: menuClassList,
        setAttribute(name, value) {
          this.attributes[name] = value;
        }
      };

      controller.connect();
      controller.toggleSidebar();
      controller.disconnect();

      if (!observerDisconnected) {
        throw new Error("Expected disconnect() to stop the mutation observer when matchMedia is unavailable");
      }

      if (controller.mobileMenuTarget.attributes["aria-hidden"] !== "false") {
        throw new Error(`Expected open menu aria-hidden=false without matchMedia, saw ${controller.mobileMenuTarget.attributes["aria-hidden"]}`);
      }
    }

    runModernListenerCase();
    runLegacyListenerCase();
    runMissingMatchMediaCase();
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ChatSessionListControllerNodeHarness, :no_db do
  it "toggles the mobile sidebar and supports legacy media query listeners" do
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
