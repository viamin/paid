# frozen_string_literal: true

module Ci
  class FailureContext
    GREEN_CONCLUSIONS = %w[success skipped neutral].freeze
    DEFAULT_MAX_CHARS = LogExtractor::DEFAULT_MAX_CHARS
    DEFAULT_MAX_WORKFLOW_CHARS = 6_000

    FAILURE_TYPE_PATTERNS = {
      database: /NoDatabaseError|database.*does not exist|PG::ConnectionBad|Mysql2::Error::ConnectionError/i,
      environment: /command not found|unknown command|no such file or directory.*config/i,
      dependency: /Gem::(LoadError|MissingSpecError|RequirementNotMetError)|LoadError.*cannot load|npm ERR!.*ENOENT|ModuleNotFoundError/i,
      service: /Connection refused|ECONNREFUSED|service.*unavailable|could not connect/i,
      timeout: /Timeout::Error|timed?\s*out|deadline exceeded|Net::ReadTimeout/i
    }.freeze

    attr_reader :checks, :output, :failure_types, :workflow_content

    def self.call(...)
      new(...).build
    end

    def initialize(repo:, checks:, github_client:, max_chars: DEFAULT_MAX_CHARS, ref: nil)
      @repo = repo
      @checks = Array(checks)
      @github_client = github_client
      @max_chars = max_chars
      @ref = ref
      @output = ""
      @failure_types = []
      @workflow_content = ""
    end

    def build
      @checks = failed_checks
      @output = extracted_output
      @failure_types = classify_failure_types
      @workflow_content = fetch_workflow_content
      self
    end

    def failing?
      checks.any?
    end

    private

    attr_reader :repo, :github_client, :max_chars, :ref

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

      LogExtractor.call(redact(raw), max_chars: remaining)
    end

    def classify_failure_types
      return [] if output.blank?

      FAILURE_TYPE_PATTERNS.filter_map do |type, pattern|
        type if output.match?(pattern)
      end
    end

    def fetch_workflow_content
      return "" if checks.empty?

      run_ids = checks.filter_map { |c| self.class.actions_run_id_from_url(c[:details_url]) }.uniq
      return "" if run_ids.empty?

      paths = run_ids.filter_map { |rid| workflow_path_for_run(rid) }.uniq
      return "" if paths.empty?

      fetch_and_combine_workflow_files(paths)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "ci.failure_context_workflow_fetch_failed",
        repo: repo,
        error_class: e.class.name
      )
      ""
    end

    def self.actions_run_id_from_url(url)
      url.to_s[%r{/actions/runs/(\d+)/}, 1]
    end

    def workflow_path_for_run(run_id)
      run = github_client.actions_run(repo, run_id)
      run&.path
    rescue GithubClient::Error
      nil
    end

    def fetch_and_combine_workflow_files(paths)
      remaining = DEFAULT_MAX_WORKFLOW_CHARS
      sections = []

      paths.each do |path|
        content = github_client.file_content(repo, path: path, ref: ref)
        next if content.blank?

        section = "### #{path}\n\n```yaml\n#{content.strip}\n```"
        sections << section
        remaining -= section.length
        break if remaining <= 0
      end

      sections.join("\n\n")
    end

    def redact(text)
      normalized = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      Knowledge::Redaction::Redactor.call(text: normalized).clean_text
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
