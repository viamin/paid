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

        // Replace fenced code blocks first so the trailing-newline replacement
        // below leaves the block contents intact for the chat-message code
        // copy-button tests.
        const escaped = input.replace(/```([a-zA-Z0-9_-]*)\\n([\\s\\S]*?)```/g,
          (_match, language, code) => {
            const langClass = language ? ` class="language-${language}"` : "";
            const escapedCode = code
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/>/g, "&gt;");
            return `<pre><code${langClass}>${escapedCode}\\n</code></pre>`;
          });

        return escaped
          .replace(/!\\[([^\\]]*)\\]\\(([^)]*)\\)/g, (_match, text) => renderer.image({ text }))
          .replace(/\\[([^\\]]+)\\]\\(([^)]*)\\)/g, (_match, text, href) => (
            renderer.link.call(parserContext, { href, tokens: [{ text }], text })
          ))
          .replace(/\\*\\*(.+?)\\*\\*/g, "<strong>$1</strong>")
          .replace(/\\n/g, "<br>");
      }
    };

    const safeMarkdownSource = fs.readFileSync("app/javascript/lib/safe_markdown.js", "utf8");
    const transformedSafeMarkdown = safeMarkdownSource
      .replace('import { marked } from "marked"', "")
      .replace("export { SAFE_URL_SCHEMES, escapeHtml, renderMarkdown }", "return { SAFE_URL_SCHEMES, escapeHtml, renderMarkdown }");

    const { renderMarkdown } = new Function("marked", transformedSafeMarkdown)(marked);

    const source = fs.readFileSync("app/javascript/controllers/chat_message_controller.js", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace('import { renderMarkdown } from "../lib/safe_markdown"', "")
      .replace('import hljs from "highlight.js/lib/common"', "const hljs = { highlightElement() {} }")
      .replace("export default class extends Controller {", "return class ChatMessageController extends Controller {");

    const ChatMessageController = new Function("renderMarkdown", transformed)(renderMarkdown);

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

    // Minimal DOM used by the copy-button tests. Only implements the subset
    // of the DOM API that chat_message_controller.js touches during
    // decorateCodeBlocks and legacyCopy: element creation, classList,
    // dataset, append, replaceWith, appendChild/removeChild for the
    // execCommand fallback textarea, and execCommand.
    function createMockElement(tagName) {
      const children = [];
      const classSet = new Set();
      const dataset = {};
      const attributes = {};
      const style = new Proxy({}, {
        set(target, prop, value) {
          target[prop] = value;
          return true;
        }
      });
      const element = {
        tagName: tagName.toUpperCase(),
        type: "",
        value: "",
        children,
        className: "",
        dataset,
        style,
        parentElement: null,
        selected: false,
        attributes,
        get textContent() {
          let out = "";
          const walk = (node) => {
            if (node.tagName === "TEXT" || node.tagName === "#text") {
              out += node.__text || "";
            }
            node.children.forEach(walk);
          };
          walk(element);
          return out;
        },
        set textContent(value) {
          const textNode = createMockElement("text");
          textNode.__text = String(value);
          children.length = 0;
          children.push(textNode);
          textNode.parentElement = element;
        },
        select() {
          this.selected = true;
        },
        focus() {},
        setAttribute(name, value) {
          attributes[name] = value;
        },
        getAttribute(name) {
          return attributes[name];
        },
        classList: {
          add(...names) {
            names.forEach((name) => classSet.add(name));
            element.className = [...classSet].join(" ");
          },
          remove(...names) {
            names.forEach((name) => classSet.delete(name));
            element.className = [...classSet].join(" ");
          },
          contains(name) {
            return classSet.has(name);
          },
          *[Symbol.iterator]() {
            yield* classSet;
          }
        },
        append(...nodes) {
          nodes.forEach((node) => {
            if (node && typeof node === "object") {
              const existingIdx = node.parentElement
                ? node.parentElement.children.indexOf(node)
                : -1;
              if (existingIdx >= 0) node.parentElement.children.splice(existingIdx, 1);
              node.parentElement = element;
              children.push(node);
            }
          });
        },
        appendChild(node) {
          element.append(node);
          return node;
        },
        removeChild(node) {
          const idx = children.indexOf(node);
          if (idx >= 0) {
            children.splice(idx, 1);
            node.parentElement = null;
          }
          return node;
        },
        replaceWith(...replacements) {
          if (!element.parentElement) return;
          const parent = element.parentElement;
          const index = parent.children.indexOf(element);
          parent.children.splice(index, 1, ...replacements);
          replacements.forEach((node) => { node.parentElement = parent; });
          element.parentElement = null;
        },
        closest(selector) {
          let cursor = element;
          while (cursor) {
            if (selector.startsWith("[data-")) {
              const attr = selector.slice(6, -1);
              if (cursor.dataset && cursor.dataset[attr] !== undefined) return cursor;
            } else if (cursor.tagName === selector.toUpperCase()) {
              return cursor;
            }
            cursor = cursor.parentElement;
          }
          return null;
        },
        querySelectorAll(selector) {
          const matches = [];
          const visit = (node) => {
            if (matchesSelector(node, selector)) matches.push(node);
            node.children.forEach(visit);
          };
          children.forEach(visit);
          return matches;
        }
      };
      return element;
    }

    function matchesSelector(node, selector) {
      if (selector.includes(">")) {
        const [parentSel, childSel] = selector.split(/\\s*>\\s*/);
        if (!node.parentElement) return false;
        if (!matchesSelector(node.parentElement, parentSel.trim())) return false;
        return matchesSelector(node, childSel.trim());
      }
      if (selector.startsWith("pre")) return node.tagName === "PRE";
      if (selector.startsWith("code")) return node.tagName === "CODE";
      return false;
    }

    function parseHtmlIntoMockDom(html) {
      const root = createMockElement("div");
      const stack = [root];
      const tagPattern = /<(\\/?)([a-zA-Z0-9]+)([^>]*)>|([^<]+)/g;
      let match;
      while ((match = tagPattern.exec(html)) !== null) {
        const [, closing, tagName, attrs, text] = match;
        if (text !== undefined) {
          const parent = stack[stack.length - 1];
          if (!parent) continue;
          const textNode = createMockElement("text");
          textNode.textContent = text;
          parent.append(textNode);
          continue;
        }
        if (closing) {
          if (stack.length > 1) stack.pop();
          continue;
        }
        const node = createMockElement(tagName);
        const classMatch = attrs.match(/class="([^"]*)"/);
        if (classMatch) {
          classMatch[1].split(/\\s+/).filter(Boolean).forEach((name) => {
            node.classList.add(name);
          });
        }
        const parent = stack[stack.length - 1];
        parent.append(node);
        if (!attrs.endsWith("/") && !["br", "img", "hr", "input"].includes(tagName.toLowerCase())) {
          stack.push(node);
        }
      }
      return root;
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

    function testStreamingReasoningIsHiddenUntilAnswerArrives() {
      const { controller, content } = makeController("");

      controller.appendContent("<thi");
      if (content.innerHTML !== "") throw new Error(`Partial tag was shown: ${content.innerHTML}`);

      controller.appendContent("nk>private reasoning");
      if (content.innerHTML !== "") throw new Error(`Reasoning was shown: ${content.innerHTML}`);

      controller.appendContent("</think>\\n\\n**Answer**");
      if (!content.innerHTML.includes("<strong>Answer</strong>")) {
        throw new Error(`Answer was not shown: ${content.innerHTML}`);
      }
      if (content.innerHTML.includes("think") || content.innerHTML.includes("reasoning")) {
        throw new Error(`Reasoning leaked into transcript: ${content.innerHTML}`);
      }
    }

    // Builds a controller whose contentTarget already contains a pre > code
    // block rendered from the supplied markdown. Runs decorateCodeBlocks to
    // exercise the same wiring the production DOM does, then locates the
    // generated Copy button and returns it together with the controller.
    function makeControllerWithCodeBlock(rawMarkdown) {
      const classes = new Set(["chat-markdown"]);
      const content = {
        dataset: { rawContent: rawMarkdown },
        innerHTML: renderMarkdown(rawMarkdown),
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
        }
      };

      const dom = parseHtmlIntoMockDom(content.innerHTML);
      content.querySelectorAll = (selector) => dom.querySelectorAll(selector);

      const controller = Object.create(ChatMessageController.prototype);
      controller.markdownValue = true;
      controller.hasContentTarget = true;
      controller.contentTarget = content;

      controller.decorateCodeBlocks();

      const buttons = [];
      const collect = (node) => {
        if (node.tagName === "BUTTON") buttons.push(node);
        node.children.forEach(collect);
      };
      dom.children.forEach(collect);

      return { controller, dom, copyButton: buttons[0] };
    }

    // Each scenario runs in its own try/finally so a synchronous assertion
    // failure cannot tear down the controller's mock window before the
    // async copyCode settles. The harness runs scenarios sequentially and
    // surfaces the first failure as an unhandled rejection.
    async function scenario(name, overrides, body) {
      const clipboardCalls = [];
      const execCommandCalls = [];
      const consoleWarns = [];

      const clipboard = {
        writeText: (text) => {
          clipboardCalls.push(text);
          if (overrides.clipboardThrows) {
            return Promise.reject(new Error(overrides.clipboardThrowsMessage || "clipboard rejected"));
          }
          return Promise.resolve();
        }
      };

      const execCommand = (command) => {
        execCommandCalls.push(command);
        return overrides.execCommandReturns === false ? false : true;
      };

      const documentMock = {
        createElement: (tag) => createMockElement(tag),
        body: createMockElement("body"),
        activeElement: null,
        execCommand
      };

      const windowMock = {
        navigator: overrides.clipboardApiMissing ? {} : { clipboard },
        setTimeout: () => 0,
        console: {
          warn: (msg, err) => consoleWarns.push({ msg, err, level: "warn" }),
          error: (msg, err) => consoleWarns.push({ msg, err, level: "error" })
        }
      };

      const previousWindow = globalThis.window;
      const previousDocument = globalThis.document;
      const previousNavigator = globalThis.navigator;
      const previousSetTimeout = globalThis.setTimeout;

      globalThis.window = windowMock;
      globalThis.document = documentMock;
      globalThis.navigator = overrides.clipboardApiMissing ? {} : { clipboard };
      globalThis.setTimeout = () => 0;

      try {
        await body({ clipboardCalls, execCommandCalls, consoleWarns });
      } finally {
        globalThis.window = previousWindow;
        globalThis.document = previousDocument;
        globalThis.navigator = previousNavigator;
        globalThis.setTimeout = previousSetTimeout;
      }
    }

    function testCopyButtonWritesToClipboardViaApi() {
      return scenario("writes-to-clipboard-api", {}, async ({ clipboardCalls }) => {
        const rawMarkdown = "```yup\\nlet x = 1\\n```";
        const { controller, copyButton } = makeControllerWithCodeBlock(rawMarkdown);

        if (!copyButton) throw new Error("Expected decorateCodeBlocks to render a Copy button");
        if (copyButton.dataset.action !== "chat-message#copyCode") {
          throw new Error(`Expected data-action chat-message#copyCode, got: ${copyButton.dataset.action}`);
        }
        if (copyButton.dataset.copyContent !== "let x = 1") {
          throw new Error(`Expected copyContent to capture code block text, got: ${JSON.stringify(copyButton.dataset.copyContent)}`);
        }

        await controller.copyCode({ currentTarget: copyButton });

        if (clipboardCalls.length !== 1) {
          throw new Error(`Expected clipboard.writeText to be called once, got ${clipboardCalls.length}`);
        }
        if (clipboardCalls[0] !== "let x = 1") {
          throw new Error(`Expected clipboard.writeText to receive code text, got: ${JSON.stringify(clipboardCalls[0])}`);
        }
        if (copyButton.textContent !== "Copied") {
          throw new Error(`Expected button to show 'Copied' after success, got: ${copyButton.textContent}`);
        }
      });
    }

    function testCopyButtonFallsBackToExecCommandWhenClipboardApiFails() {
      return scenario("falls-back-to-execCommand", {
        clipboardThrows: true,
        clipboardThrowsMessage: "Write permission denied."
      }, async ({ clipboardCalls, execCommandCalls }) => {
        const rawMarkdown = "```ruby\\nputs :hi\\n```";
        const { controller, copyButton } = makeControllerWithCodeBlock(rawMarkdown);

        await controller.copyCode({ currentTarget: copyButton });

        if (clipboardCalls.length !== 1) {
          throw new Error(`Expected clipboard.writeText to be attempted, got ${clipboardCalls.length} calls`);
        }
        if (execCommandCalls.length !== 1 || execCommandCalls[0] !== "copy") {
          throw new Error(`Expected execCommand('copy') fallback, got: ${JSON.stringify(execCommandCalls)}`);
        }
        if (copyButton.textContent !== "Copied") {
          throw new Error(`Expected button to show 'Copied' after execCommand fallback, got: ${copyButton.textContent}`);
        }
      });
    }

    function testCopyButtonShowsFailureWhenBothPathsFail() {
      return scenario("shows-failure-when-both-paths-fail", {
        clipboardThrows: true,
        clipboardThrowsMessage: "Write permission denied.",
        execCommandReturns: false
      }, async ({ execCommandCalls, consoleWarns }) => {
        const rawMarkdown = "```bash\\necho hi\\n```";
        const { controller, copyButton } = makeControllerWithCodeBlock(rawMarkdown);

        await controller.copyCode({ currentTarget: copyButton });

        if (execCommandCalls.length !== 1) {
          throw new Error(`Expected execCommand fallback to be attempted, got ${execCommandCalls.length} calls`);
        }
        if (copyButton.textContent !== "Copy failed") {
          throw new Error(`Expected button to show 'Copy failed', got: ${copyButton.textContent}`);
        }
        if (consoleWarns.length !== 1) {
          throw new Error(`Expected failure to be surfaced via console.warn, got ${consoleWarns.length} calls`);
        }
        if (!/clipboard write failed/.test(consoleWarns[0].msg)) {
          throw new Error(`Expected console.warn message to mention clipboard failure, got: ${consoleWarns[0].msg}`);
        }
      });
    }

    function testCopyButtonWorksWithoutClipboardApi() {
      return scenario("works-without-clipboard-api", {
        clipboardApiMissing: true
      }, async ({ execCommandCalls }) => {
        const rawMarkdown = "```text\\nplain\\n```";
        const { controller, copyButton } = makeControllerWithCodeBlock(rawMarkdown);

        await controller.copyCode({ currentTarget: copyButton });

        if (execCommandCalls.length !== 1 || execCommandCalls[0] !== "copy") {
          throw new Error(`Expected execCommand fallback when navigator.clipboard is missing, got: ${JSON.stringify(execCommandCalls)}`);
        }
        if (copyButton.textContent !== "Copied") {
          throw new Error(`Expected 'Copied' after execCommand fallback, got: ${copyButton.textContent}`);
        }
      });
    }

    function testCopyButtonHandlesEmptyContent() {
      return scenario("handles-empty-content", {}, async ({ clipboardCalls }) => {
        const { controller, copyButton } = makeControllerWithCodeBlock("```\\n\\n```");
        if (!copyButton) throw new Error("Expected decorateCodeBlocks to render a Copy button");
        copyButton.dataset.copyContent = "";

        await controller.copyCode({ currentTarget: copyButton });

        if (clipboardCalls.length !== 1) {
          throw new Error(`Expected clipboard.writeText to be called once for empty content, got ${clipboardCalls.length}`);
        }
        if (clipboardCalls[0] !== "") {
          throw new Error(`Expected clipboard.writeText to receive empty string, got: ${JSON.stringify(clipboardCalls[0])}`);
        }
        if (copyButton.textContent !== "Copied") {
          throw new Error(`Expected button to show 'Copied' for empty content, got: ${copyButton.textContent}`);
        }
      });
    }

    async function run() {
      testMarkdownRendersSafeHtml();
      testMarkdownFailureFallsBackToText();
      testMarkdownSuccessRemovesFallbackFormatting();
      testStreamingReasoningIsHiddenUntilAnswerArrives();

      await testCopyButtonWritesToClipboardViaApi();
      await testCopyButtonFallsBackToExecCommandWhenClipboardApiFails();
      await testCopyButtonShowsFailureWhenBothPathsFail();
      await testCopyButtonWorksWithoutClipboardApi();
      await testCopyButtonHandlesEmptyContent();
    }

    run().then(() => {
      // success
    }).catch((error) => {
      console.error(error.message || error);
      process.exit(1);
    });
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
