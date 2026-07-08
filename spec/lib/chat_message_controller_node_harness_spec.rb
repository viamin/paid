# frozen_string_literal: true

require "open3"
require "rails_helper"

class ChatMessageControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    class Renderer {
      constructor() {
        this.parser = {
          parseInline(tokens) {
            return tokens.map((token) => token.text || token.raw || "").join("");
          }
        };
      }
    }

    const marked = {
      Renderer,
      parse(input, { renderer }) {
        const parserContext = { parser: new Renderer().parser };

        return input
          .replace(/!\\[([^\\]]*)\\]\\(([^)]*)\\)/g, (_match, text) => renderer.image({ text }))
          .replace(/\\[([^\\]]+)\\]\\(([^)]*)\\)/g, (_match, text, href) => (
            renderer.link.call(parserContext, { href, tokens: [{ text }], text })
          ))
          .replace(/\\*\\*(.+?)\\*\\*/g, "<strong>$1</strong>")
          .replace(/\\n/g, "<br>");
      }
    };

    const source = fs.readFileSync("app/javascript/controllers/chat_message_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace('import { marked } from "marked"', "")
      .replace('import hljs from "highlight.js/lib/common"', "const hljs = { highlightElement() {} }")
      .replace("export default class extends Controller {", "return class ChatMessageController extends Controller {");

    const ChatMessageController = new Function("marked", transformed)(marked);

    function makeController(rawContent) {
      const classes = new Set(["chat-markdown"]);
      const controller = Object.create(ChatMessageController.prototype);
      const content = {
        dataset: { rawContent },
        innerHTML: "",
        textContent: "",
        className: "chat-markdown",
        classList: {
          add(...tokens) {
            tokens.forEach((token) => classes.add(token));
            content.className = [...classes].join(" ");
          },
          remove(...tokens) {
            tokens.forEach((token) => classes.delete(token));
            content.className = [...classes].join(" ");
          },
          contains(token) {
            return classes.has(token);
          }
        },
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
      if (!content.classList.contains("whitespace-pre-wrap") || !content.classList.contains("break-words")) {
        throw new Error(`Expected fallback to preserve whitespace, got classes: ${content.className}`);
      }
      if (content.innerHTML) {
        throw new Error(`Expected fallback not to write innerHTML, got: ${content.innerHTML}`);
      }
    }

    function testMarkdownSuccessRemovesFallbackFormatting() {
      const { controller, content } = makeController("line one\\nline two");
      content.classList.add("whitespace-pre-wrap", "break-words");

      controller.render();

      if (content.classList.contains("whitespace-pre-wrap") || content.classList.contains("break-words")) {
        throw new Error(`Expected successful parse to clear fallback classes, got: ${content.className}`);
      }
    }

    function run() {
      testMarkdownRendersSafeHtml();
      testMarkdownFailureFallsBackToText();
      testMarkdownSuccessRemovesFallbackFormatting();
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
