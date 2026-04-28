# frozen_string_literal: true

module Automation
  module Strategies
    class AutoMerge
      # Immutable input for {Strategies::AutoMerge}. Carries the pre-computed
      # signals that determine whether a pull request is eligible for
      # automatic merging.
      #
      # Signals are provider-neutral: the calling layer (e.g.
      # +ScanPaidPrsActivity+) resolves provider-specific data into boolean
      # preconditions before constructing this object. The strategy operates
      # purely on these booleans, keeping policy independent of I/O.
      #
      # == Precondition fields
      #
      # * +owner_approved+ — the project owner has approved the PR, or the
      #   owner is the PR author (self-authored bypass).
      # * +checks_green+ — every CI check run has a green conclusion
      #   (+success+, +skipped+, or +neutral+).
      # * +mergeable+ — the repository host reports the PR as mergeable
      #   (no conflicts at merge time).
      # * +review_feedback_clear+ — no unresolved review threads, bot
      #   findings, changes-requested reviews, or conversation comments
      #   that should block the merge.
      # * +blocking_reviews_complete+ — every enabled blocking review
      #   method (+ci_action+, +manual+) has a completion signal.
      # * +reviews_fresh+ — the HEAD commit was not pushed after the
      #   latest blocking approval(s).
      # * +bot_authored+ — the PR was created by a known bot user
      #   (Dependabot, Renovate, etc.).
      # * +dependabot_eligible+ — the project allows auto-merging
      #   bot-authored PRs (+auto_merge_dependabot?+).
      class Signals < ::Data.define(
        :issue_id,
        :pr_number,
        :owner_approved,
        :checks_green,
        :mergeable,
        :review_feedback_clear,
        :blocking_reviews_complete,
        :reviews_fresh,
        :bot_authored,
        :dependabot_eligible
      )
        class << self
          # Builds a Signals from keyword arguments, defaulting boolean
          # fields to +false+ when not provided.
          def build(issue_id:, pr_number:, **kwargs)
            new(
              issue_id: issue_id,
              pr_number: pr_number,
              owner_approved: kwargs.fetch(:owner_approved, false),
              checks_green: kwargs.fetch(:checks_green, false),
              mergeable: kwargs.fetch(:mergeable, false),
              review_feedback_clear: kwargs.fetch(:review_feedback_clear, false),
              blocking_reviews_complete: kwargs.fetch(:blocking_reviews_complete, false),
              reviews_fresh: kwargs.fetch(:reviews_fresh, false),
              bot_authored: kwargs.fetch(:bot_authored, false),
              dependabot_eligible: kwargs.fetch(:dependabot_eligible, false)
            )
          end
        end

        def owner_approved? = owner_approved == true
        def checks_green? = checks_green == true
        def mergeable? = mergeable == true
        def review_feedback_clear? = review_feedback_clear == true
        def blocking_reviews_complete? = blocking_reviews_complete == true
        def reviews_fresh? = reviews_fresh == true
        def bot_authored? = bot_authored == true
        def dependabot_eligible? = dependabot_eligible == true
      end
    end
  end
end
