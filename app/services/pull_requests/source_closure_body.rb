# frozen_string_literal: true

module PullRequests
  # Normalizes source-issue closing syntax after the authoritative disposition
  # has been recorded. This is textual publication safety, not a completion
  # decision: PartialCloseouts::SourceClosureDisposition owns that decision.
  # @spec PARTIAL-CLOSEOUT-029
  class SourceClosureBody
    CLOSING_KEYWORDS = %w[Close Closes Closed Fix Fixes Fixed Resolve Resolves Resolved].join("|")

    def self.call(...) = new(...).call

    def initialize(body:, issue:, project:, disposition:)
      @body = body.to_s
      @issue = issue
      @project = project
      @disposition = disposition.to_s
    end

    def call
      return body if issue.nil?

      reference = disposition == PartialCloseouts::SourceClosureDisposition::CLOSE ? "Closes #{issue_reference}" : "Tracks #{issue_reference}"
      pattern = source_reference_pattern
      return body.gsub(pattern, reference) if body.match?(pattern)

      "#{body.rstrip}\n\n---\n\n#{reference}"
    end

    private

    attr_reader :body, :issue, :project, :disposition

    def issue_reference
      return "##{issue.github_number}" unless project.upstream_pr_target?

      "#{project.issue_target_repository}##{issue.github_number}"
    end

    def source_reference_pattern
      /\b(?:Tracks|#{CLOSING_KEYWORDS})\s*:?[ \t]+(?:#{source_issue_references})\b/i
    end

    def source_issue_references
      [ "##{issue.github_number}", "#{project.issue_target_repository}##{issue.github_number}" ]
        .map { |reference| Regexp.escape(reference) }
        .join("|")
    end
  end
end
