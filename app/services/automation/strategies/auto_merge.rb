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
    # @spec AUTO-MERGE-001
    # @spec AUTO-MERGE-002
    # @spec AUTO-MERGE-005
    class AutoMerge
      include Automation::Strategy

      SIGNALS_KEY = :auto_merge_signals
      SKIP_AUTO_MERGE_LABEL = "paid-skip-auto-merge"
      SIGNAL_STATUS_FAILED = "failed"
      SIGNAL_STATUS_NOT_EVALUATED = "not_evaluated"

      Blocker = ::Data.define(:signal, :status, :reason_code, :sanitized_message, :next_action) do
        def failed? = status == SIGNAL_STATUS_FAILED
        def not_evaluated? = status == SIGNAL_STATUS_NOT_EVALUATED

        def to_h
          {
            signal: signal.to_s,
            status:,
            reason_code:,
            sanitized_message:,
            next_action:
          }
        end
      end

      Evaluation = ::Data.define(:eligible, :blockers) do
        def eligible? = eligible == true
        def failed_blockers = blockers.select(&:failed?)
        def not_evaluated_blockers = blockers.select(&:not_evaluated?)
      end

      HUMAN_SIGNAL_DEFINITIONS = [
        [ :owner_approved, "owner_approval_missing" ],
        [ :checks_green, "checks_not_green" ],
        [ :mergeable, "not_mergeable" ],
        [ :review_feedback_clear, "review_feedback_pending" ],
        [ :blocking_reviews_complete, "blocking_reviews_incomplete" ],
        [ :reviews_fresh, "stale_approval" ],
        [ :dependencies_resolved, "dependencies_unresolved" ]
      ].freeze

      BOT_SIGNAL_DEFINITIONS = [
        [ :dependabot_eligible, "dependabot_auto_merge_disabled" ],
        [ :checks_green, "checks_not_green" ],
        [ :mergeable, "not_mergeable" ],
        [ :dependencies_resolved, "dependencies_unresolved" ]
      ].freeze

      # @param context [Automation::Context]
      # @return [Automation::Result]
      def evaluate(context)
        config = Configuration::AutoMerge.from_project(context.project)
        return noop_result unless config.enabled?

        signals = context.metadata_fetch(SIGNALS_KEY)
        return noop_result if signals.nil?
        analysis = analyze(signals, owner_reviewer_login: context.project.owner_reviewer_login)

        return noop_result unless analysis.eligible?

        Result.new(decisions: [
          Decision.merge(issue_id: signals.issue_id, pr_number: signals.pr_number)
        ])
      end

      def analyze(signals, owner_reviewer_login:)
        blockers = skip_auto_merge_blockers(signals, owner_reviewer_login:)
        signal_definitions = signals.bot_authored? ? BOT_SIGNAL_DEFINITIONS : HUMAN_SIGNAL_DEFINITIONS
        blockers.concat(signal_blockers(signals, signal_definitions, owner_reviewer_login:))

        Evaluation.new(eligible: blockers.none?(&:failed?), blockers:)
      end

      private

      def skip_auto_merge_blockers(signals, owner_reviewer_login:)
        return [] unless signals.skip_auto_merge?

        [
          blocker_for(:skip_auto_merge, SIGNAL_STATUS_FAILED, "skip_auto_merge",
            owner_reviewer_login:)
        ]
      end

      def signal_blockers(signals, definitions, owner_reviewer_login:)
        blockers = []
        prior_failed = false

        definitions.each do |signal_name, reason_code|
          value = signals.public_send("#{signal_name}?")

          if signal_name == :dependencies_resolved && prior_failed
            blockers << blocker_for(signal_name, SIGNAL_STATUS_NOT_EVALUATED, reason_code,
              owner_reviewer_login:) unless value
            next
          end

          next if value

          blockers << blocker_for(signal_name, SIGNAL_STATUS_FAILED, reason_code, owner_reviewer_login:)
          prior_failed = true
        end

        blockers
      end

      def blocker_for(signal_name, status, reason_code, owner_reviewer_login:)
        Blocker.new(
          signal: signal_name.to_s,
          status:,
          reason_code:,
          sanitized_message: sanitized_message_for(signal_name, status),
          next_action: next_action_for(signal_name, status, owner_reviewer_login:)
        )
      end

      def sanitized_message_for(signal_name, status)
        return "Dependency resolution was not evaluated because an earlier auto-merge gate already failed." if status == SIGNAL_STATUS_NOT_EVALUATED

        case signal_name
        when :owner_approved
          "The required owner approval is missing."
        when :checks_green
          "Required checks are not green yet."
        when :mergeable
          "GitHub is not reporting this pull request as mergeable yet."
        when :review_feedback_clear
          "Outstanding review feedback still blocks auto-merge."
        when :blocking_reviews_complete
          "Required blocking reviews are not complete yet."
        when :reviews_fresh
          "The owner approval is stale for the current HEAD commit."
        when :dependencies_resolved
          "One or more declared dependencies are not resolved yet."
        when :dependabot_eligible
          "Dependency auto-merge is not enabled for this project."
        when :skip_auto_merge
          "The paid-skip-auto-merge label is preventing automatic merge."
        else
          "Auto-merge is blocked."
        end
      end

      def next_action_for(signal_name, status, owner_reviewer_login:)
        return "Resolve the earlier auto-merge blockers first, then let Paid re-evaluate dependency resolution." if status == SIGNAL_STATUS_NOT_EVALUATED

        reviewer_handle = owner_reviewer_login.present? ? "@#{owner_reviewer_login}" : "the configured owner reviewer"

        case signal_name
        when :owner_approved
          "Ask #{reviewer_handle} to approve this pull request, then wait for the next automatic merge evaluation."
        when :checks_green
          "Wait for required checks to pass, then let auto-merge evaluate the pull request again."
        when :mergeable
          "Resolve merge conflicts or other mergeability blockers, then wait for the next automatic check."
        when :review_feedback_clear
          "Resolve the outstanding review feedback, then wait for the next automatic merge evaluation."
        when :blocking_reviews_complete
          "Complete the remaining blocking reviews, then wait for the next automatic merge evaluation."
        when :reviews_fresh
          "Ask #{reviewer_handle} to re-approve this pull request for the current HEAD commit, then wait for the next automatic merge evaluation."
        when :dependencies_resolved
          "Merge or remove the blocking dependencies, then let Paid evaluate this pull request again."
        when :dependabot_eligible
          "Enable dependency auto-merge for this project or merge this pull request manually."
        when :skip_auto_merge
          "Remove the paid-skip-auto-merge label or merge this pull request manually."
        else
          "Resolve the blocker, then let Paid evaluate this pull request again."
        end
      end
    end
  end
end
