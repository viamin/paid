# frozen_string_literal: true

module Ci
  # Builds bounded, pre-processed CI failure context for agent prompts.
  class FailureContext
    GREEN_CONCLUSIONS = %w[success skipped neutral].freeze
    DEFAULT_MAX_CHARS = LogExtractor::DEFAULT_MAX_CHARS

    attr_reader :checks, :output

    def self.call(...)
      new(...).build
    end

    def initialize(repo:, checks:, github_client:, max_chars: DEFAULT_MAX_CHARS)
      @repo = repo
      @checks = Array(checks)
      @github_client = github_client
      @max_chars = max_chars
      @output = ""
    end

    def build
      @checks = failed_checks
      @output = extracted_output
      self
    end

    def failing?
      checks.any?
    end

    private

    attr_reader :repo, :github_client, :max_chars

    def failed_checks
      checks.select do |check|
        conclusion = check[:conclusion].to_s
        conclusion.present? && !GREEN_CONCLUSIONS.include?(conclusion)
      end
    end

    def extracted_output
      remaining = max_chars
      sections = []

      checks.each do |check|
        extracted = extract_check_output(check, remaining)
        next if extracted.blank?

        section = "## #{check[:name]}\n\n#{extracted.strip}"
        sections << section
        remaining = max_chars - sections.join("\n\n").length
        break unless remaining.positive?
      end

      sections.join("\n\n")
    end

    def extract_check_output(check, remaining)
      raw = raw_check_output(check)
      return "" if raw.blank?

      LogExtractor.call(raw, max_chars: remaining)
    end

    def raw_check_output(check)
      [
        check[:output_text],
        check_log(check)
      ].compact_blank.join("\n\n")
    end

    def check_log(check)
      github_client.check_run_log(repo, check)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "ci.failure_context_log_fetch_failed",
        repo: repo,
        check_name: check[:name],
        check_run_id: check[:id],
        error_class: e.class.name
      )
      nil
    end
  end
end
