# frozen_string_literal: true

module PullRequests
  # Normalizes source-issue closing syntax after the authoritative disposition
  # has been recorded. This is textual publication safety, not a completion
  # decision: PartialCloseouts::SourceClosureDisposition owns that decision.
  # @spec PARTIAL-CLOSEOUT-029
  class SourceClosureBody
    CLOSING_KEYWORDS = "Closes|Fixes|Resolves"

    def self.call(...) = new(...).call

    def initialize(body:, issue:, project:, disposition:)
      @body = body.to_s
      @issue = issue
      @project = project
      @disposition = disposition.to_s
    end

    def call
      return body if issue.nil?

      normalized = body.gsub(closing_reference_pattern, "Tracks #{issue_reference}")
      return normalized unless disposition == PartialCloseouts::SourceClosureDisposition::CLOSE

      "#{normalized.rstrip}\n\n---\n\nCloses #{issue_reference}"
    end

    private

    attr_reader :body, :issue, :project, :disposition

    def issue_reference
      return "##{issue.github_number}" unless project.upstream_pr_target?

      "#{project.issue_target_repository}##{issue.github_number}"
    end

    def closing_reference_pattern
      /\b(?:#{CLOSING_KEYWORDS})\s*:?[ \t]+#{Regexp.escape(issue_reference)}\b/i
    end
  end
end
