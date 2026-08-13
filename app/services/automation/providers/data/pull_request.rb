# frozen_string_literal: true

module Automation
  module Providers
    module Data
        # Provider-neutral pull-request snapshot. Returned by
        # {Automation::Providers::RepositoryProvider#fetch_pull_request} and
        # {Automation::Providers::RepositoryProvider#list_pull_requests}.
        #
        # Fields:
        # - +number+ [Integer] Provider-local PR number.
        # - +title+ [String]
        # - +body+ [String, nil] Markdown body.
        # - +state+ [Symbol] One of {STATES}. Providers MUST normalize to
        #   these values.
        # - +draft+ [Boolean] +true+ for draft/WIP PRs.
        # - +merged+ [Boolean] +true+ when the PR has been merged.
        # - +mergeable+ [Boolean, nil] +nil+ when the provider has not yet
        #   computed mergeability; +true+/+false+ otherwise.
        # - +head_sha+ [String] Commit SHA at the tip of the source branch.
        # - +head_ref+ [String] Source branch ref.
        # - +base_ref+ [String] Target branch ref.
        # - +author_login+ [String, nil] Login of the PR author, downcased.
        # - +labels+ [Array<String>] Label names currently applied.
        # - +created_at+ [Time]
        # - +updated_at+ [Time]
        # - +merged_at+ [Time, nil] Nil when not merged.
        # - +url+ [String, nil] Browser-viewable URL.
        # - +raw_state+ [String, nil] The provider's native state label,
        #   preserved for audit when +state+ normalization loses detail.
        # - +head_repo_fork+ [Boolean, nil] +true+ when the PR head lives on
        #   a fork. Automation uses this to gate operations a fork cannot
        #   fulfill (e.g. dispatching a GitHub Actions review workflow).
        #   +nil+ when the provider does not report fork status.
        class PullRequest < ::Data.define(
          :number,
          :title,
          :body,
          :state,
          :draft,
          :merged,
          :mergeable,
          :head_sha,
          :head_ref,
          :base_ref,
          :author_login,
          :labels,
          :created_at,
          :updated_at,
          :merged_at,
          :url,
          :raw_state,
          :head_repo_fork
        )
          STATES = %i[open closed].freeze

          # +head_repo_fork+ was added after the data class shipped, so it
          # defaults to +nil+ to keep existing constructor call sites
          # (which predate fork reporting) working without modification.
          def initialize(number:, title:, body:, state:, draft:, merged:, mergeable:,
            head_sha:, head_ref:, base_ref:, author_login:, labels:, created_at:,
            updated_at:, merged_at:, url:, raw_state:, head_repo_fork: nil)
            super
          end
        end
    end
  end
end
