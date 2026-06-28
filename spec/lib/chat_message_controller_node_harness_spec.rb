# frozen_string_literal: true

require "open3"
require "rails_helper"

class ChatMessageControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");
    const { marked } = require("marked");

    const source = fs.readFileSync("app/javascript/controllers/chat_message_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace('import { marked } from "marked"', "")
      .replace('import hljs from "highlight.js/lib/common"', "const hljs = { highlightElement() {} }")
      .replace("export default class extends Controller {", "return class ChatMessageController extends Controller {");

    const ChatMessageController = new Function("marked", transformed)(marked);

    function makeController(rawContent) {
      const controller = Object.create(ChatMessageController.prototype);
      const content = {
        dataset: { rawContent },
        innerHTML: "",
        textContent: "",
        querySelectorAll: () => []
      };

      controller.markdownValue = true;
      controller.hasContentTarget = true;
      controller.contentTarget = content;

      return { controller, content };
    }

    function testMarkdownRendersSafeHtml() {
      const { controller, content } = makeController(
        "**safe** [ok](https://example.com) [bad](javascript:alert(1)) ![hidden](https://example.com/image.png)"
      );

      controller.render();

      if (!content.innerHTML.includes("<strong>safe</strong>")) {
        throw new Error(`Expected bold Markdown to render, got: ${content.innerHTML}`);
      }
      if (!content.innerHTML.includes('href="https://example.com"')) {
        throw new Error(`Expected safe link to render, got: ${content.innerHTML}`);
      }
      if (content.innerHTML.includes("javascript:")) {
        throw new Error(`Expected unsafe link href to be stripped, got: ${content.innerHTML}`);
      }
      if (content.innerHTML.includes("<img")) {
        throw new Error(`Expected images to be suppressed, got: ${content.innerHTML}`);
      }
    }

    function testMarkdownFailureFallsBackToText() {
      const originalParse = marked.parse;
      const { controller, content } = makeController("<script>alert(1)</script>");

      marked.parse = () => { throw new Error("parse failed"); };
      try {
        controller.render();
      } finally {
        marked.parse = originalParse;
      }

      if (content.textContent !== "<script>alert(1)</script>") {
        throw new Error(`Expected raw text fallback, got: ${content.textContent}`);
      }
      if (content.innerHTML) {
        throw new Error(`Expected fallback not to write innerHTML, got: ${content.innerHTML}`);
      }
    }

    function run() {
      testMarkdownRendersSafeHtml();
      testMarkdownFailureFallsBackToText();
    }

    try {
      run();
    } catch (error) {
      console.error(error.message || error);
      process.exit(1);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe ChatMessageControllerNodeHarness, :no_db do
  it "renders Markdown safely and fails closed" do
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
