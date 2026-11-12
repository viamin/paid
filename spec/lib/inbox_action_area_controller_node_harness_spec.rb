# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxActionAreaControllerNodeHarness; end

# @spec OPERATOR-INBOX-028
RSpec.describe InboxActionAreaControllerNodeHarness do
  it "moves the existing action controls into the sticky action area without cloning them" do
    stdout, stderr, status = Open3.capture3("node", stdin_data: harness_script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to include("moved" => [ true, true ], "hiddenRemoved" => true)
  end

  private

  def harness_script
    <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_action_area_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxActionAreaController extends Controller {")
      const InboxActionAreaController = new Function(transformed)()

      const actionArea = {
        classList: { removed: [], remove(name) { this.removed.push(name) } },
        append(...nodes) { nodes.forEach((node) => { node.parentNode = this }) }
      }
      const form = { parentNode: null, dataset: {}, classList: { add() {} } }
      const link = { parentNode: null, dataset: {}, classList: { add() {} } }
      const content = {
        querySelectorAll(selector) {
          if (selector !== "form, a.inline-flex") throw new Error(`unexpected selector: ${selector}`)
          return [form, link]
        }
      }
      const controller = Object.create(InboxActionAreaController.prototype)
      controller.actionsTarget = actionArea
      controller.contentTarget = content
      controller.collectActions()
      process.stdout.write(JSON.stringify({
        moved: [form.parentNode === actionArea, link.parentNode === actionArea],
        hiddenRemoved: actionArea.classList.removed.includes("hidden")
      }))
    JAVASCRIPT
  end
end
