# frozen_string_literal: true

module Automation
  module Strategies
    # Auto-merge strategy — decides whether a pull request satisfies all
    # preconditions for automatic merging.
    #
    # The strategy is pure policy: it performs no I/O. Signal collection
    # (fetching reviews, checks, threads) remains in the upstream scan
    # layer, which pre-computes boolean preconditions into an
    # {AutoMerge::Signals} object. The strategy evaluates those signals
    # and returns a {Decision.merge} when eligible, or a noop result
    # when any precondition fails.
    #
    # == Eligibility paths
    #
    # *Human-authored PRs* must satisfy all of:
    # - Auto-merge enabled on the project
    # - Owner approval (or self-authored bypass)
    # - All CI checks green
    # - PR mergeable (no conflicts)
    # - No outstanding review feedback
    # - All blocking review methods complete
    # - Reviews not stale for HEAD
    # - Dependency PRs already merged
    #
    # *Bot-authored PRs* (Dependabot, Renovate) have a simpler path:
    # - Auto-merge enabled on the project
    # - Dependabot auto-merge enabled
    # - All CI checks green
    # - PR mergeable
    # - Dependency PRs already merged
    #
    # Bot-authored PRs skip owner-approval and review-feedback gates
    # because bot dependency updates are treated as trusted.
    class AutoMerge
      include Automation::Strategy

      SIGNALS_KEY = :auto_merge_signals
      SKIP_AUTO_MERGE_LABEL = "paid-skip-auto-merge"

      # @param context [Automation::Context]
      # @return [Automation::Result]
      def evaluate(context)
        config = Configuration::AutoMerge.from_project(context.project)
        return noop_result unless config.enabled?

        signals = context.metadata_fetch(SIGNALS_KEY)
        return noop_result if signals.nil?
        return noop_result if signals.skip_auto_merge?

        eligible = if signals.bot_authored?
          bot_eligible?(signals)
        else
          human_eligible?(signals)
        end

        return noop_result unless eligible

        Result.new(decisions: [
          Decision.merge(issue_id: signals.issue_id, pr_number: signals.pr_number)
        ])
      end

      private

      def human_eligible?(signals)
        signals.owner_approved? &&
          signals.checks_green? &&
          signals.mergeable? &&
          signals.review_feedback_clear? &&
          signals.blocking_reviews_complete? &&
          signals.reviews_fresh? &&
          signals.dependencies_resolved?
      end

      def bot_eligible?(signals)
        signals.dependabot_eligible? &&
          signals.checks_green? &&
          signals.mergeable? &&
          signals.dependencies_resolved?
      end
    end
  end
end
