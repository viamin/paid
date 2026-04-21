# frozen_string_literal: true

module Automation
  module Strategies
    # Auto-review strategy — owns the policy that translates a PR scan's
    # review-related triggers and counters into {Automation::Decision}
    # objects. Each configured review method
    # (+copilot+ / +paid_agent+ / +codex+ / +ci_action+ / +manual+) is
    # represented by a plugin under {Automation::ReviewMethods}; the
    # strategy calls each enabled plugin, aggregates their
    # {Outcome} reports, and composes a prioritized decision list that
    # preserves current mixed-provider behavior.
    #
    # == High-level outcomes
    #
    # Per-method plugins report one of:
    #
    # * +:pending+            — review work still outstanding.
    # * +:satisfied+          — review complete for this PR head.
    # * +:retryable_failure+  — failure, but retry budget remains.
    # * +:exhausted_retries+  — failure with no retries left.
    # * +:not_applicable+     — method disabled or out of scope.
    #
    # A pending outcome may be either +blocking+ (the PR cannot advance
    # until satisfied — e.g. paid_agent as sole method, or manual/ci_action
    # when +wait_for_reviews+ is on) or a non-blocking +sidecar+ (the PR
    # continues through follow-up work while the review is requested).
    #
    # == Mixed-provider handling
    #
    # When multiple review methods are enabled, the strategy:
    #
    # 1. Evaluates every enabled method, producing one outcome per method.
    # 2. Emits each plugin's proposed decision (e.g. +queue_review_run+ for
    #    paid_agent, +request_review+ for copilot/codex/manual) — so every
    #    provider gets the chance to advance its own review concurrently.
    # 3. Adds follow-up / ready / escalate / merge decisions based on the
    #    non-review triggers present in the scan, unless a blocking
    #    outcome forbids advancing (e.g. paid_agent_review_pending as the
    #    sole method suppresses +queue_create_pr_run+ per #1135).
    #
    # This matches the behavior previously encoded in
    # {Automation::PullRequestEvaluator} while making the per-method policy
    # pluggable and the outcome vocabulary explicit.
    class AutoReview
      include Automation::Strategy

      FOLLOWUP_TRIGGER_TYPES = %w[
        ci_failure review_threads conversation_comments changes_requested
        actionable_labels merge_conflicts review_bot_comments review_bot_threads
      ].freeze

      # Scan may be provided via +context.metadata[:scan]+; when absent,
      # the strategy emits a noop result (this mirrors the behavior of
      # {Automation::PullRequestEvaluator} when called without explicit
      # scan data).
      #
      # @param context [Automation::Context]
      # @return [Automation::Result]
      def evaluate(context)
        scan = context.metadata_fetch(:scan)
        return noop_result if scan.nil?

        config = Automation::Configuration::AutoReview.from_project(context.project)
        signals = AutoReview::Signals.from_scan(scan)
        plugins = build_plugins(config, signals)
        outcomes = plugins.map(&:evaluate)

        decisions = compose_decisions(signals, plugins, outcomes)
        Automation::Result.new(decisions: decisions.presence || [ Automation::Decision.noop ])
      end

      # Evaluates just the per-method outcomes for a given project and
      # scan, without composing the decision list. Useful for callers that
      # want to inspect review state (e.g. the explicit scan tree in
      # {Automation::PullRequestEvaluator}) without committing to a
      # decision composition.
      #
      # @return [Array<Outcome>]
      def outcomes_for(project:, scan:)
        config = Automation::Configuration::AutoReview.from_project(project)
        signals = AutoReview::Signals.from_scan(scan)
        build_plugins(config, signals).map(&:evaluate)
      end

      private

      # Instantiates a plugin for every known review method, whether or
      # not the project has it enabled. The plugins themselves decide
      # what state to report based on both signals and config, so the
      # scan-trigger-driven routing from {PullRequestEvaluator} continues
      # to work even when a trigger is present for a method the config
      # reports as disabled (e.g. in focused specs that exercise trigger
      # routing without fully configuring review_settings).
      def build_plugins(config, signals)
        Automation::Configuration::ReviewMethod::NAMES.map do |name|
          method = config.method_for(name)
          plugin_class = Automation::ReviewMethods::Registry.resolve(name)
          plugin_class.new(method: method, config: config, signals: signals)
        end
      end

      def compose_decisions(signals, plugins, outcomes)
        decisions = []
        trigger_types = signals.trigger_types

        if trigger_types.include?("escalate_to_owner")
          decisions << escalate_decision(signals)
          return decisions
        end

        if trigger_types.include?("dismiss_escalation")
          decisions << Automation::Decision.dismiss_escalation(issue_id: signals.issue_id)
          return decisions
        end

        if trigger_types.include?("owner_approved")
          decisions << Automation::Decision.merge(issue_id: signals.issue_id, pr_number: signals.pr_number)
          return decisions
        end

        if trigger_types.include?("review_goal_retry")
          return review_goal_retry_decisions(signals, plugins, outcomes, trigger_types)
        end

        if trigger_types.include?("ready_for_owner")
          return ready_for_owner_decisions(signals, plugins, outcomes, trigger_types)
        end

        if trigger_types.include?(Automation::ReviewMethods::PaidAgent::TRIGGER_TYPE)
          return paid_agent_pending_decisions(plugins)
        end

        if trigger_types.include?(Automation::ReviewMethods::Copilot::TRIGGER_TYPE)
          return review_bot_pending_decisions(plugins, signals, trigger_types)
        end

        if trigger_types.include?(Automation::ReviewMethods::Manual::TRIGGER_TYPE) ||
           trigger_types.include?(Automation::ReviewMethods::CiAction::TRIGGER_TYPE)
          return non_bot_pending_decisions(plugins, signals, trigger_types)
        end

        followup_decisions(signals)
      end

      def paid_agent_pending_decisions(plugins)
        # paid_agent_review_pending is a hard gate: emit only the
        # queue_review_run decision and suppress create_pr follow-up runs
        # while the review is outstanding (#1135).
        paid_plugin = plugins.find { |p| p.name == :paid_agent }
        decision = paid_plugin&.decision
        decision ? [ decision ] : []
      end

      def review_bot_pending_decisions(plugins, _signals, _trigger_types)
        # Bot review pending is a hard gate, matching paid_agent_review_pending:
        # request/queue the review action only and wait for the next scan before
        # starting any create_pr follow-up work. (#1336)
        review_bot_request_decisions(plugins)
      end

      def non_bot_pending_decisions(plugins, signals, trigger_types)
        decisions = manual_request_decisions(plugins)

        other_triggers = trigger_types - [
          Automation::ReviewMethods::Manual::TRIGGER_TYPE,
          Automation::ReviewMethods::CiAction::TRIGGER_TYPE
        ]
        decisions.concat(followup_decisions(signals)) if other_triggers.any?
        decisions
      end

      def ready_for_owner_decisions(signals, plugins, outcomes, trigger_types)
        decisions = []

        paid_pending = trigger_types.include?(Automation::ReviewMethods::PaidAgent::TRIGGER_TYPE)
        paid_active = outcomes.any? { |o| o.method == :paid_agent && o.pending? && o.metadata[:active_run] }

        if paid_pending && !paid_active
          paid_decision = plugins.find { |p| p.name == :paid_agent }&.decision
          decisions << paid_decision if paid_decision
        end

        decisions << Automation::Decision.mark_ready(
          issue_id: signals.issue_id,
          pr_number: signals.pr_number,
          owner_reviewer_login: signals.owner_reviewer_login
        )

        decisions
      end

      def review_goal_retry_decisions(signals, plugins, outcomes, trigger_types)
        decisions = [
          Automation::Decision.record_review_goal_retry(
            issue_id: signals.issue_id,
            expected_review_goal_retry_count: signals.review_goal_retry_count
          )
        ]

        paid_decision = plugins.find { |p| p.name == :paid_agent }&.decision
        decisions << paid_decision if paid_decision

        if trigger_types.include?("ready_for_owner")
          sans_paid = without_trigger(signals, Automation::ReviewMethods::PaidAgent::TRIGGER_TYPE)
          decisions.concat(
            ready_for_owner_decisions(sans_paid, plugins, outcomes, sans_paid.trigger_types)
          )
          return decisions
        end

        decisions.concat(manual_request_decisions(plugins))

        if signals.triggers.any? { |t| FOLLOWUP_TRIGGER_TYPES.include?(t[:type].to_s) }
          decisions.concat(followup_decisions(signals))
        else
          decisions.concat(review_bot_request_decisions(plugins))
        end

        decisions
      end

      def review_bot_request_decisions(plugins)
        bot_plugins = plugins.select { |p| p.kind == :bot || p.kind == :comment_bot }
        bot_plugins.filter_map(&:decision)
      end

      def manual_request_decisions(plugins)
        plugins.select { |p| p.kind == :human }.filter_map(&:decision)
      end

      def followup_decisions(signals)
        if signals.draft_phase?
          [
            Automation::Decision.queue_create_pr_run(
              issue_id: signals.issue_id,
              source_pull_request_number: signals.pr_number,
              count_toward_draft_review_round: true,
              expected_draft_review_count: signals.draft_review_count
            )
          ]
        else
          [
            Automation::Decision.queue_create_pr_run(
              issue_id: signals.issue_id,
              source_pull_request_number: signals.pr_number
            ),
            Automation::Decision.record_pr_followup(
              issue_id: signals.issue_id,
              labels_to_remove: signals.labels_to_remove,
              expected_followup_count: signals.followup_count
            )
          ]
        end
      end

      def escalate_decision(signals)
        trigger = signals.trigger("escalate_to_owner") || {}
        Automation::Decision.escalate(
          issue_id: signals.issue_id,
          pr_number: signals.pr_number,
          owner_reviewer_login: signals.owner_reviewer_login,
          reason: trigger[:details]
        )
      end

      def without_trigger(signals, type)
        filtered = signals.triggers.reject { |t| t[:type].to_s == type.to_s }
        Signals.new(
          issue_id: signals.issue_id,
          pr_number: signals.pr_number,
          phase: signals.phase,
          triggers: filtered.freeze,
          counters: signals.counters,
          owner_reviewer_login: signals.owner_reviewer_login,
          labels_to_remove: signals.labels_to_remove
        )
      end
    end
  end
end
