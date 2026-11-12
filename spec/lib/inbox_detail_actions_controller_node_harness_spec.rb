# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxDetailActionsControllerNodeHarness; end

# @spec OPERATOR-INBOX-027
RSpec.describe InboxDetailActionsControllerNodeHarness do
  it "activates the original rendered control instead of reimplementing its action" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_detail_actions_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxDetailActionsController extends Controller {")
      const InboxDetailActionsController = new Function(transformed)()

      const result = { focused: 0, clicked: 0 }
      const sourceControl = {
        disabled: false,
        getAttribute() { return null },
        value: "Continue",
        focus() { result.focused += 1 },
        click() { result.clicked += 1 }
      }
      const controller = Object.create(InboxDetailActionsController.prototype)
      controller.statusTarget = { textContent: "" }
      controller.controls = () => [sourceControl]
      controller.activate({ currentTarget: { dataset: { sourceIndex: "0" } } })
      process.stdout.write(JSON.stringify(result))
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq("focused" => 0, "clicked" => 1)
  end

  it "keeps disabled controls inert in the action header" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_detail_actions_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxDetailActionsController extends Controller {")
      const InboxDetailActionsController = new Function(transformed)()

      const result = { focused: 0, clicked: 0 }
      const sourceControl = {
        disabled: true,
        getAttribute() { return null },
        focus() { result.focused += 1 },
        click() { result.clicked += 1 }
      }
      const controller = Object.create(InboxDetailActionsController.prototype)
      controller.controls = () => [sourceControl]
      controller.activate({ currentTarget: { dataset: { sourceIndex: "0" } } })
      process.stdout.write(JSON.stringify(result))
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq("focused" => 0, "clicked" => 0)
  end
end
