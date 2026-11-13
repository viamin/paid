# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxActionsControllerNodeHarness; end

# @spec OPERATOR-INBOX-027
RSpec.describe InboxActionsControllerNodeHarness do
  def run_harness
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_actions_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxActionsController extends Controller {")
      const InboxActionsController = new Function(transformed)()

      const result = { actionLinkClicks: 0, contextualLinkClicks: 0, decisions: [], labels: [] }
      const submitters = [
        { tagName: "BUTTON", textContent: "Repair", name: "decision", value: "repair", disabled: false },
        { tagName: "BUTTON", textContent: "Clarify", name: "decision", value: "clarify", disabled: false },
        { tagName: "BUTTON", textContent: "Defer", name: "decision", value: "defer", disabled: true },
        { tagName: "INPUT", type: "submit", textContent: "", value: "File issue and link finding", disabled: false }
      ]
      submitters.forEach((submitter) => {
        submitter.click = function() {
          if (!this.disabled) result.decisions.push([ this.name, this.value ])
        }
      })
      const actionLink = {
        tagName: "A",
        textContent: "Open settings",
        inboxAction: true,
        href: "/projects/7/edit",
        target: "_blank",
        rel: "noopener noreferrer",
        cloneNode() {
          return { tagName: this.tagName, href: this.href, target: this.target, rel: this.rel }
        },
        click() { result.actionLinkClicks += 1 }
      }
      const contextualLink = { tagName: "A", textContent: "Evidence #123", click() { result.contextualLinkClicks += 1 } }
      const allControls = [ actionLink, contextualLink, ...submitters ]
      const actionSource = {
        querySelectorAll(selector) {
          result.selector = selector
          return allControls.filter((control) =>
            control.inboxAction || control.tagName === "BUTTON" || control.type === "submit"
          )
        }
      }
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
      global.window = {
        MutationObserver: class {
          constructor(callback) { this.callback = callback; observers.push(this) }
          observe(target, options) { this.target = target; this.options = options }
          disconnect() { this.disconnected = true }
        }
      }

      const controller = Object.create(InboxActionsController.prototype)
      controller.hasBarTarget = true
      controller.barTarget = bar
      controller.sourceTarget = actionSource
      controller.connect()
      bar.children.forEach((proxy) => {
        result.labels.push(proxy.textContent)
        if (proxy.listener) proxy.listener()
      })
      result.actionLink = {
        tagName: bar.children[0].tagName,
        href: bar.children[0].href,
        target: bar.children[0].target,
        rel: bar.children[0].rel
      }
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
    JSON.parse(stdout)
  end

  it "projects every form action and designated action link while synchronizing disabled state" do
    expect(run_harness).to eq(
      "actionLinkClicks" => 0,
      "contextualLinkClicks" => 0,
      "actionLink" => {
        "tagName" => "A",
        "href" => "/projects/7/edit",
        "target" => "_blank",
        "rel" => "noopener noreferrer"
      },
      "decisions" => [
        [ "decision", "repair" ],
        [ "decision", "clarify" ],
        [ nil, "File issue and link finding" ]
      ],
      "labels" => [ "Open settings", "Repair", "Clarify", "Defer", "File issue and link finding" ],
      "selector" => "button, input[type='submit'], input[type='image'], [data-inbox-action]",
      "firstProxyDisabled" => true,
      "thirdProxyDisabled" => true,
      "observedAttributes" => [ [ "disabled" ], [ "disabled" ], [ "disabled" ], [ "disabled" ] ],
      "observersDisconnected" => true
    )
  end
end
