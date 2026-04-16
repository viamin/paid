# frozen_string_literal: true

module Automation
  module Strategies
    # Auto-pick selection policy, extracted from {Issues::AutoPick}.
    #
    # The strategy is pure policy — it performs no I/O of its own. Given
    # an {Automation::Context} that carries project-level guard signals
    # (open-PR attention counts, configured limits) and a CandidateSource
    # for data access, it returns an {Automation::Result} describing
    # whether to queue a new +create_pr+ agent run for some issue.
    #
    # Responsibilities:
    # - Enforce project-level guards: +auto_pick_enabled+ and the WIP cap
    #   on PRs still needing attention.
    # - Ask the candidate source for the next work item that satisfies
    #   per-issue eligibility and prioritization rules.
    # - Emit a {Decision.queue_create_pr_run} decision when a candidate is
    #   available, or a noop result when work should be deferred.
    #
    # Orchestration concerns (resolving the provider, executing the
    # decision by creating an AgentRun, logging, dedup) remain in
    # {Issues::AutoPick}.
    class AutoPick
      include Automation::Strategy

      # Metadata keys read from {Automation::Context#metadata}.
      PR_ATTENTION_COUNT_KEY = :pr_attention_count
      PR_ATTENTION_LIMIT_KEY = :pr_attention_limit

      # @param candidate_source [#next_candidate] Provider-backed data
      #   access for auto-pick candidates. Defaults to the local-DB /
      #   GitHub-backed {DefaultCandidateSource}.
      def initialize(candidate_source: DefaultCandidateSource)
        @candidate_source = candidate_source
      end

      # @param context [Automation::Context]
      # @return [Automation::Result]
      def evaluate(context)
        project = context.project
        return noop_result unless auto_pick_enabled?(project)
        return noop_result if deferred_by_pr_attention_limit?(context)

        issue = @candidate_source.next_candidate(project)
        return noop_result unless issue

        Result.new(decisions: [ Decision.queue_create_pr_run(issue_id: issue.id) ])
      end

      private

      def auto_pick_enabled?(project)
        Configuration::AutoPick.from_project(project).enabled?
      end

      # When the configured limit is zero there is no cap — auto-pick is
      # never deferred on that signal. A positive limit defers auto-pick
      # once the number of PRs still needing attention reaches it.
      def deferred_by_pr_attention_limit?(context)
        limit = context.metadata_fetch(PR_ATTENTION_LIMIT_KEY, 0).to_i
        return false if limit <= 0

        count = context.metadata_fetch(PR_ATTENTION_COUNT_KEY, 0).to_i
        count >= limit
      end
    end
  end
end
