# frozen_string_literal: true

module StyleGuides
  # Extracts coding style conventions from a project's codebase using LLM analysis.
  # Collects representative code samples, groups by language, and generates
  # StyleGuide records with extracted conventions.
  #
  # @example
  #   result = StyleGuides::Extract.call(project: project)
  #   result.style_guides  # => [#<StyleGuide>, ...]
  #   result.languages     # => ["ruby", "typescript"]
  class ExtractionError < StandardError; end

  class Extract
    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 120

    # Proper display names for languages to avoid inconsistencies like
    # "Typescript" vs "TypeScript" in user-facing guide names.
    LANGUAGE_DISPLAY_NAMES = {
      "ruby" => "Ruby",
      "javascript" => "JavaScript",
      "typescript" => "TypeScript",
      "python" => "Python",
      "go" => "Go",
      "rust" => "Rust"
    }.freeze

    EXTRACTION_PROMPT = <<~PROMPT
      You are a senior software engineer. Analyze the following code samples from a %{language} codebase and extract the coding style conventions you observe.

      Output a concise style guide covering:
      - Naming conventions (variables, methods, classes, files)
      - Formatting patterns (indentation, line length, spacing)
      - Code organization (module structure, imports, file layout)
      - Common patterns and idioms used
      - Error handling conventions
      - Testing patterns (if test files are included)

      Rules:
      - Only document conventions actually present in the code — do not invent rules
      - Use terse bullet points grouped by category
      - Include short code snippets only when they clarify a pattern
      - Output plain text with markdown formatting
      - Keep the guide under 3000 words

      Code samples:
    PROMPT

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      samples = CollectCodeSamples.call(project: project)

      if samples.empty?
        return Result.new(style_guides: [], languages: [])
      end

      created_guides = []

      samples.each do |language, file_samples|
        guide = extract_for_language(language, file_samples)
        created_guides << guide if guide
      end

      Result.new(
        style_guides: created_guides,
        languages: created_guides.map(&:language)
      )
    end

    private

    def extract_for_language(language, file_samples)
      prompt = build_prompt(language, file_samples)
      response = send_to_llm(prompt)
      validate_response!(response)

      create_style_guide(language, response.output)
    end

    def build_prompt(language, file_samples)
      header = format(EXTRACTION_PROMPT, language: language)
      body = file_samples.map { |s| "## #{s[:path]}\n```\n#{s[:content]}\n```" }.join("\n\n")
      "#{header}\n\n#{body}"
    end

    def send_to_llm(prompt)
      AgentHarness.send_message(
        prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        dangerous_mode: false
      )
    end

    def validate_response!(response)
      success = !response.respond_to?(:success?) || response.success?
      output = response.output

      return if success && output.present?

      raise ExtractionError, "LLM extraction failed or returned empty output"
    end

    def create_style_guide(language, content)
      display_name = LANGUAGE_DISPLAY_NAMES.fetch(language, language.capitalize)
      guide_name = "#{display_name} Style Guide (auto-extracted)"

      existing = project.style_guides.find_by(name: guide_name)
      if existing
        existing.update!(raw_content: content, language: language, active: true)
        StyleGuideCompressionJob.perform_later(existing.id)
        return existing
      end

      guide = project.style_guides.create!(
        name: guide_name,
        raw_content: content,
        language: language,
        account: project.account,
        active: true
      )

      StyleGuideCompressionJob.perform_later(guide.id)
      guide
    end

    # Result object returned by Extract.
    class Result
      attr_reader :style_guides, :languages

      def initialize(style_guides:, languages:)
        @style_guides = style_guides
        @languages = languages
      end

      def any_extracted?
        style_guides.any?
      end
    end
  end
end
