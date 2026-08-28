# frozen_string_literal: true

module Reviews
  # Identifies GitHub logins that belong to automation rather than a human
  # reviewer. Shared by the PR scan (Activities::ScanPaidPrsActivity), the
  # awaiting_approval escalation re-validation
  # (PullRequests::BlockedOnlyOnApproval), and Reviews::BlockingMethodsComplete,
  # all of which need to exclude bot comments/reviews from human-trust gates.
  module BotDetection
    KNOWN_BOT_PREFIXES = %w[dependabot renovate github-actions].freeze

    def self.bot_user?(login)
      return false if login.blank?

      normalized = login.downcase
      return true if normalized.end_with?("[bot]", "-bot")

      KNOWN_BOT_PREFIXES.any? { |prefix| normalized.start_with?(prefix) }
    end
  end
end
