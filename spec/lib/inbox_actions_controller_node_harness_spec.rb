# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxActionsControllerNodeHarness; end

# @spec OPERATOR-INBOX-027
RSpec.describe InboxActionsControllerNodeHarness do
  it "projects each submitter and synchronizes its disabled state" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_actions_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxActionsController extends Controller {")
      const InboxActionsController = new Function(transformed)()

      const result = { linkClicks: 0, decisions: [], labels: [] }
      const submitters = [
        { tagName: "BUTTON", textContent: "Repair", name: "decision", value: "repair", disabled: false },
        { tagName: "BUTTON", textContent: "Clarify", name: "decision", value: "clarify", disabled: false },
        { tagName: "BUTTON", textContent: "Defer", name: "decision", value: "defer", disabled: true }
      ]
      submitters.forEach((submitter) => {
        submitter.click = function() {
          if (!this.disabled) result.decisions.push([ this.name, this.value ])
        }
      })
      const link = { tagName: "A", textContent: "View issue", click() { result.linkClicks += 1 } }
      const bar = {
        contains() { return false },
        replaceChildren(...children) { this.children = children }
      }
      global.document = {
        createElement() {
          return {
            addEventListener(_event, listener) { this.listener = listener },
            className: "",
            textContent: ""
          }
        }
      }
      const observers = []
      global.MutationObserver = class {
        constructor(callback) { this.callback = callback; observers.push(this) }
        observe(target, options) { this.target = target; this.options = options }
        disconnect() { this.disconnected = true }
      }

      const controller = Object.create(InboxActionsController.prototype)
      controller.hasBarTarget = true
      controller.barTarget = bar
      controller.element = {
        querySelectorAll(selector) {
          result.selector = selector
          return [ link, ...submitters ]
        }
      }
      controller.connect()
      bar.children.forEach((proxy) => { result.labels.push(proxy.textContent); proxy.listener() })
      submitters[0].disabled = true
      observers[0].callback()
      result.firstProxyDisabled = bar.children[1].disabled
      result.thirdProxyDisabled = bar.children[3].disabled
      result.observedAttributes = observers.map((observer) => observer.options.attributeFilter)
      controller.disconnect()
      result.observersDisconnected = observers.every((observer) => observer.disconnected)
      process.stdout.write(JSON.stringify(result))
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq(
      "linkClicks" => 1,
      "decisions" => [ [ "decision", "repair" ], [ "decision", "clarify" ] ],
      "labels" => [ "View issue", "Repair", "Clarify", "Defer" ],
      "selector" => "a[href], button[type='submit'], input[type='submit'], input[type='image'], form button:not([type])",
      "firstProxyDisabled" => true,
      "thirdProxyDisabled" => true,
      "observedAttributes" => [ [ "disabled" ], [ "disabled" ], [ "disabled" ] ],
      "observersDisconnected" => true
    )
  end
end
