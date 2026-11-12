# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxActionsControllerNodeHarness; end

# @spec OPERATOR-INBOX-027
RSpec.describe InboxActionsControllerNodeHarness do
  it "activates the original link and form submitter from toolbar proxies" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_actions_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxActionsController extends Controller {")
      const InboxActionsController = new Function(transformed)()

      const result = { linkClicks: 0, submitClicks: 0, labels: [] }
      const submitter = { textContent: "Submit answers", click() { result.submitClicks += 1 } }
      const form = { tagName: "FORM", querySelector() { return submitter } }
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

      const controller = Object.create(InboxActionsController.prototype)
      controller.hasBarTarget = true
      controller.barTarget = bar
      controller.element = { querySelectorAll() { return [ link, form ] } }
      controller.renderActions()
      bar.children.forEach((proxy) => { result.labels.push(proxy.textContent); proxy.listener() })
      process.stdout.write(JSON.stringify(result))
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)

    expect(status).to be_success, stderr
    expect(JSON.parse(stdout)).to eq(
      "linkClicks" => 1,
      "submitClicks" => 1,
      "labels" => [ "View issue", "Submit answers" ]
    )
  end
end
