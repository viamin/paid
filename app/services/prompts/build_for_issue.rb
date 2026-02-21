# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to work on a GitHub issue.
  #
  # @example
  #   prompt = Prompts::BuildForIssue.call(issue: issue, project: project)
  #   # => "# Task\n\nYou are working on..."
  class BuildForIssue
    class UntrustedIssueError < StandardError; end

    LANGUAGE_TEST_COMMANDS = {
      "ruby" => "bundle exec rspec",
      "javascript" => "npm test",
      "typescript" => "npm test",
      "python" => "pytest",
      "go" => "go test ./...",
      "rust" => "cargo test"
    }.freeze

    LANGUAGE_LINT_COMMANDS = {
      "ruby" => "bundle exec rubocop",
      "javascript" => "npm run lint",
      "typescript" => "npm run lint",
      "python" => "ruff check .",
      "go" => "golangci-lint run",
      "rust" => "cargo clippy"
    }.freeze

    CONTEXT_LIMIT = 10

    attr_reader :issue, :project

    def initialize(issue:, project:)
      @issue = issue
      @project = project
    end

    def self.call(...)
      new(...).build
    end

    def build
      raise UntrustedIssueError, "Cannot build prompt for issue from untrusted user: #{issue.github_creator_login}" unless issue.trusted?

      sections = []
      sections << task_section
      sections << codebase_context_section if codebase_context.any?
      sections << instructions_section
      sections << important_section
      sections.join("\n")
    end

    private

    def task_section
      <<~SECTION
        # Task

        You are working on the following GitHub issue:

        **#{issue.title}** (##{issue.github_number})

        #{issue.body}
      SECTION
    end

    def codebase_context_section
      chunks = codebase_context.map do |chunk|
        "## #{chunk.file_path}:#{chunk.start_line}-#{chunk.end_line} (#{chunk.chunk_type}: #{chunk.identifier})\n\n```#{chunk.language}\n#{chunk.content}\n```"
      end

      <<~SECTION
        # Relevant Codebase Context

        The following code snippets from the repository may be relevant to this issue:

        #{chunks.join("\n\n")}
      SECTION
    end

    def instructions_section
      <<~SECTION
        # Instructions

        1. Analyze the issue and understand what needs to be done
        2. Make the necessary code changes
        3. Ensure tests pass (run `#{test_command}` if available)
        4. Ensure linting passes (run `#{lint_command}` if available)
        5. Commit your changes with a descriptive message
      SECTION
    end

    def important_section
      <<~SECTION
        # Important

        - Work within the existing codebase style and conventions
        - Do not modify unrelated files
        - If you're unsure about something, leave a comment in the code
        - Focus on completing the specific task in the issue

        When you're done, commit all your changes. Do not push.
      SECTION
    end

    def codebase_context
      @codebase_context ||= fetch_codebase_context
    end

    def fetch_codebase_context
      query_text = [ issue.title, issue.body ].compact.join("\n")
      SemanticSearch::Query.call(
        query: query_text,
        project: project,
        mode: :text,
        limit: CONTEXT_LIMIT
      ).to_a
    rescue => e
      Rails.logger.warn(
        message: "prompt_builder.semantic_search_failed",
        project_id: project.id,
        error: e.message
      )
      []
    end

    def test_command
      LANGUAGE_TEST_COMMANDS.fetch(detected_language, "echo \"No test command configured\"")
    end

    def lint_command
      LANGUAGE_LINT_COMMANDS.fetch(detected_language, "echo \"No lint command configured\"")
    end

    def detected_language
      @detected_language ||= detect_language
    end

    def detect_language
      return project.detected_language if project.respond_to?(:detected_language) && project.detected_language.present?

      # Default to Ruby when detected_language is unavailable
      "ruby"
    end
  end
end
