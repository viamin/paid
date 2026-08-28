# frozen_string_literal: true

module Reviews
  # Whether every check run in a fetched check-run list is passing (or
  # exempt). Shared by the PR scan (Activities::ScanPaidPrsActivity) and the
  # awaiting_approval escalation re-validation
  # (PullRequests::BlockedOnlyOnApproval) so both apply the same
  # "green" definition to the same check-run payload shape.
  module ChecksStatus
    def self.all_green?(checks)
      return true if checks.empty?

      checks.all? { |c| %w[success skipped neutral].include?(c[:conclusion]) }
    end
  end
end
