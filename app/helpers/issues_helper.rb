# frozen_string_literal: true

module IssuesHelper
  ISSUE_KIND_LABELS = {
    short: { issue: "Issue", pull_request: "PR" },
    short_lower: { issue: "issue", pull_request: "PR" },
    long: { issue: "issue", pull_request: "pull request" }
  }.freeze

  # @spec OPERATOR-INBOX-007
  def issue_kind_label(issue, style: :short)
    labels = ISSUE_KIND_LABELS.fetch(style)
    labels.fetch(issue.is_pull_request? ? :pull_request : :issue)
  end
end
