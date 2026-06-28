# frozen_string_literal: true

module Screenshots
  # Derives per-route screenshot hints from an agent run's change, using
  # agent_harness. Given the project's configured screenshot routes and the
  # changed files, it asks the LLM which rendered pages the change affects, a
  # one-line summary of what changed on each, and an optional CSS selector to
  # highlight.
  #
  # The result scopes screenshot capture to the affected pages and lets the
  # capture runner annotate them. It is persisted to +agent_run.screenshot_hints+
  # as a Hash keyed by route name:
  #
  #   { "dashboard" => { "summary" => "Added a weekly cost card", "selector" => "[data-testid='cost-card']" } }
  #
  # Best-effort: returns +{}+ (and leaves the column unchanged) on any failure,
  # so callers fall back to capturing every configured route.
  class DeriveHints
    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 30
    MAX_FILES = 100
    MAX_HINT_SUMMARY = 200
    MAX_SELECTOR_LENGTH = 200

    PROMPT = <<~PROMPT
      You are scoping UI screenshots for a code change. Below are the screenshot routes
      configured for an application and the files changed in the repo. Decide
      which routes render a page that this change could visibly affect.

      Respond with ONLY a JSON object (no preamble, no markdown fences) mapping each
      affected route name to an object with:
        - "summary": one short sentence describing what visibly changed on that page.
        - "selector": OPTIONAL CSS selector for the single most relevant changed element,
          or null if you cannot identify one confidently.

      Rules:
        - Bias toward inclusion. A page you omit will NOT be screenshotted, so the
          reviewer never sees it — when in doubt whether a route is affected, include it.
        - Only omit a route when you are confident the change cannot affect its page.
        - If a change is global (shared layout, global stylesheet, navigation), include
          every route.
        - Use the exact route names provided. Do not invent routes.
        - If the change genuinely cannot affect any listed page, respond with {}.

      ## Routes (name — path)
      {{routes}}

      ## Changed files
      {{changed_files}}
    PROMPT

    def self.call(agent_run:, routes:, changed_files: [], logger: Rails.logger)
      new(agent_run:, routes:, changed_files:, logger:).call
    end

    def initialize(agent_run:, routes:, changed_files:, logger:)
      @agent_run = agent_run
      @routes = Array(routes)
      @changed_files = Array(changed_files)
      @logger = logger
    end

    def call
      return {} if @routes.empty?

      hints = sanitize(request_hints)
      persist(hints)
      hints
    rescue => e
      @logger.warn(
        message: "screenshots.derive_hints_failed",
        agent_run_id: @agent_run.id,
        error: e.message,
        error_class: e.class.name
      )
      {}
    end

    private

    def request_hints
      response = AgentHarness.send_message(
        prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )
      return {} unless response.success?

      parse_json(response.output)
    end

    # Keeps only known route names with well-formed summary/selector values, so a
    # malformed or over-eager LLM response can never widen capture or inject bad
    # selectors.
    def sanitize(parsed)
      return {} unless parsed.is_a?(Hash)

      valid_names = @routes.map { |route| route.name.to_s }.to_set

      parsed.each_with_object({}) do |(name, value), result|
        name = name.to_s
        next unless valid_names.include?(name)
        next unless value.is_a?(Hash)

        summary = value["summary"].to_s.strip
        next if summary.empty?

        result[name] = {
          "summary" => summary.truncate(MAX_HINT_SUMMARY),
          "selector" => clean_selector(value["selector"])
        }.compact
      end
    end

    # A selector is fed to document.querySelector in the browser; keep it bounded
    # and single-line. querySelector cannot execute script, so this is bloat/DoS
    # hygiene rather than an XSS fix.
    def clean_selector(raw)
      selector = raw.to_s.strip
      return nil if selector.empty? || selector.length > MAX_SELECTOR_LENGTH || selector.match?(/[\r\n]/)

      selector
    end

    def persist(hints)
      @agent_run.update!(screenshot_hints: hints)
    end

    def parse_json(text)
      cleaned = strip_fence(text.to_s.strip)
      JSON.parse(cleaned)
    rescue JSON::ParserError
      {}
    end

    def strip_fence(text)
      match = text.match(/\A```(?:json)?\s*\n(.*)\n```\z/m)
      match ? match[1].strip : text
    end

    def prompt
      route_lines = @routes.map { |route| "- #{route.name} — #{route.path}" }.join("\n")
      file_lines = @changed_files.first(MAX_FILES).map { |file| "- #{file}" }.join("\n").presence || "(none reported)"

      PROMPT
        .sub("{{routes}}", route_lines)
        .sub("{{changed_files}}", file_lines)
    end
  end
end
