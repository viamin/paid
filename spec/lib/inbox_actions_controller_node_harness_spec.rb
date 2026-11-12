# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxActionsControllerNodeHarness; end

# @spec OPERATOR-INBOX-027
RSpec.describe InboxActionsControllerNodeHarness do
  def harness_result
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_actions_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxActionsController extends Controller {")
      const InboxActionsController = new Function(transformed)()

      function action(attributes = {}) {
        return {
          attributes,
          dataset: {},
          form: null,
          cloneNode() {
            const clone = action({ ...this.attributes })
            clone.textContent = this.textContent
            return clone
          },
          removeAttribute(name) { delete this.attributes[name] },
          setAttribute(name, value) { this.attributes[name] = value }
        }
      }

      const form = { id: "", attributes: {} }
      const submitter = action({ id: "submit-answers", type: "submit" })
      submitter.form = form
      const link = action({ href: "https://example.test/issues/1" })
      const actionArea = {
        children: [],
        replaceChildren() { this.children = [] },
        append(child) { this.children.push(child) }
      }
      const controller = Object.create(InboxActionsController.prototype)
      controller.actionAreaTarget = actionArea
      controller.contentTarget = {
        querySelectorAll() { return [link, submitter] }
      }

      controller.projectActions()
      process.stdout.write(JSON.stringify({
        formId: form.id,
        hidden: actionArea.hidden,
        projections: actionArea.children.map((child) => child.attributes)
      }))
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)

    expect(status).to be_success, stderr
    JSON.parse(stdout)
  end

  it "projects links and form submitters while preserving their source form" do
    result = harness_result
    link, submitter = result.fetch("projections")

    expect(result.fetch("formId")).to eq("inbox-action-form-1")
    expect(result.fetch("hidden")).to be(false)
    expect(link).to include("href" => "https://example.test/issues/1")
    expect(link).not_to have_key("id")
    expect(submitter).to include("form" => "inbox-action-form-1", "type" => "submit")
    expect(submitter).not_to have_key("id")
  end
end
