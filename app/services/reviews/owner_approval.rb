# frozen_string_literal: true

module Reviews
  # Whether the owner-approval gate for auto-merge is satisfied: either the
  # PR is exempt (the owner authored it, or a bot-authored PR is allowed to
  # skip owner sign-off) or the owner's latest review is an approval.
  # Shared by the PR scan (Activities::ScanPaidPrsActivity) and the
  # awaiting_approval escalation re-validation
  # (PullRequests::BlockedOnlyOnApproval) so a future fix to this logic
  # applies to both without a parallel edit.
  module OwnerApproval
    def self.approved_or_self_authored?(project:, reviews:, pr_data:)
      return true if author_is_owner?(project:, pr_data:)
      return true if bot_author_auto_merge_allowed?(project:, pr_data:)

      approved_from_reviews?(project:, reviews:)
    end

    def self.author_is_owner?(project:, pr_data:)
      owner_login = project.owner_reviewer_login
      author_login = pr_data&.user&.login
      return false if owner_login.blank? || author_login.blank?

      owner_login.casecmp?(author_login)
    end

    def self.bot_author_auto_merge_allowed?(project:, pr_data:)
      return false unless project.auto_merge_bot_authored?

      paid_agent_pr_author?(project:, login: pr_data&.user&.login)
    end

    # A PR authored by the project's own GitHub App agent bot (e.g.
    # "paid-agents[bot]"). Matches only the "[bot]" author login
    # (github_author_login), never the bare app slug — the slug is a
    # registerable human GitHub username and must not be treated as the
    # project's agent. Mirrors the author-trust model in
    # Project#trusted_github_author_logins.
    def self.paid_agent_pr_author?(project:, login:)
      return false if login.blank?

      agent_login = project.github_author_login
      agent_login.present? && login.casecmp?(agent_login)
    end

    # Latest-wins: an owner APPROVED review followed by a later
    # non-approving review (e.g. COMMENTED) must not count as an
    # outstanding approval.
    def self.approved_from_reviews?(project:, reviews:)
      return false if reviews.nil?

      owner_login = project.owner_reviewer_login
      return false if owner_login.blank?

      owner_reviews = reviews.select { |r| r[:user_login]&.casecmp?(owner_login) }
      latest = owner_reviews.max_by { |r| r[:submitted_at] || Time.at(0) }
      latest && latest[:state].to_s.upcase == "APPROVED"
    end
  end
end
