# frozen_string_literal: true

require "open3"
require "rails_helper"

class InboxMasterDetailControllerNodeHarness; end

# @spec OPERATOR-INBOX-026
RSpec.describe InboxMasterDetailControllerNodeHarness do
  def run_harness(mode)
    script = <<~JAVASCRIPT
      const fs = require("node:fs")
      const source = fs.readFileSync("app/javascript/controllers/inbox_master_detail_controller.js", "utf8")
      const transformed = source
        .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
        .replace("export default class extends Controller {", "return class InboxController extends Controller {")
      const InboxController = new Function(transformed)()

      const result = { clipboardWrites: [], commands: 0, status: "", warnings: 0, focused: false }
      const focusedElement = { focus() { result.focused = true } }
      const body = {
        append(element) { element.parentNode = this },
        removeChild(element) { element.parentNode = null }
      }
      global.document = {
        activeElement: focusedElement,
        body,
        createElement() {
          return {
            classList: { add() {} },
            parentNode: null,
            remove() { if (this.parentNode) this.parentNode.removeChild(this) },
            select() {},
            setAttribute() {}
          }
        },
        execCommand() {
          result.commands += 1
          return #{mode == :fallback_success ? "true" : "false"}
        }
      }
      global.window = {
        location: { origin: "https://paid.test" },
        navigator: {
          clipboard: {
            writeText(value) {
              result.clipboardWrites.push(value)
              #{mode == :native_success ? "return Promise.resolve()" : 'return Promise.reject(new Error("denied"))'}
            }
          }
        },
        console: { warn() { result.warnings += 1 } }
      }

      const controller = Object.create(InboxController.prototype)
      controller.hasCopyStatusTarget = true
      controller.copyStatusTarget = {}
      const event = {
        currentTarget: { dataset: { inboxMasterDetailCopyLinkUrl: "/inbox/example?kind=dependency_cycle" } }
      }

      controller.copyLink(event).then(() => {
        result.status = controller.copyStatusTarget.textContent
        process.stdout.write(JSON.stringify(result))
      }).catch((error) => {
        process.stderr.write(error.stack)
        process.exitCode = 1
      })
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", stdin_data: script)
    expect(status).to be_success, stderr
    JSON.parse(stdout)
  end

  it "copies the canonical URL from the rendered button dataset" do
    result = run_harness(:native_success)

    expect(result.fetch("clipboardWrites")).to eq([ "https://paid.test/inbox/example?kind=dependency_cycle" ])
    expect(result.fetch("status")).to eq("Link copied.")
  end

  it "uses the selection fallback and restores focus when clipboard permission is denied" do
    result = run_harness(:fallback_success)

    expect(result.fetch("commands")).to eq(1)
    expect(result.fetch("focused")).to be(true)
    expect(result.fetch("status")).to eq("Link copied.")
  end

  it "announces failure when both clipboard mechanisms fail" do
    result = run_harness(:failure)

    expect(result.fetch("warnings")).to eq(1)
    expect(result.fetch("focused")).to be(true)
    expect(result.fetch("status")).to eq("Copy failed.")
  end
end
