# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxDetailActionsControllerNodeHarness; end

# @spec OPERATOR-INBOX-027
RSpec.describe InboxDetailActionsControllerNodeHarness do
  it "activates the existing controls from the persistent action area" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_detail_actions_controller.js", "utf8")
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxDetailActionsController extends Controller {")
      const InboxDetailActionsController = new Function(source)()

      const form = { submissions: 0 }
      const control = {
        disabled: false,
        value: "",
        textContent: "Re-enable",
        getAttribute() { return null },
        closest(selector) { return selector === "form" ? form : null },
        click() { form.submissions += 1 }
      }
      const listeners = {}
      const sourceTarget = {
        querySelectorAll() { return [control] },
        addEventListener(name, callback) { listeners[name] = callback },
        removeEventListener() {}
      }
      const controlsTarget = {
        children: [],
        append(element) { this.children.push(element) }
      }
      const toolbarTarget = {
        classList: { toggle(name, hidden) { this[name] = hidden } }
      }
      global.document = {
        createElement() {
          return {
            attributes: {},
            listeners: {},
            setAttribute(name, value) { this.attributes[name] = value },
            addEventListener(name, callback) { this.listeners[name] = callback }
          }
        }
      }

      const controller = Object.create(InboxDetailActionsController.prototype)
      controller.sourceTarget = sourceTarget
      controller.controlsTarget = controlsTarget
      controller.toolbarTarget = toolbarTarget
      controller.connect()
      controlsTarget.children[0].listeners.click()
      process.stdout.write(JSON.stringify({
        label: controlsTarget.children[0].textContent,
        submissions: form.submissions,
        hidden: toolbarTarget.classList.hidden
      }))
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq({ "label" => "Re-enable", "submissions" => 1, "hidden" => false })
  end
end
