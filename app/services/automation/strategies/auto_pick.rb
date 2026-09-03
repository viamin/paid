# frozen_string_literal: true

module Automation
  module Strategies
    # Auto-pick selection policy, extracted from {Issues::AutoPick}.
    #
    # The strategy is pure policy — it performs no I/O of its own.
    # Given an {Automation::Context} and a CandidateSource for data
    # access, it returns an {Automation::Result} describing whether to
    # queue a new +create_pr+ agent run for some issue.
    #
    # Responsibilities:
    # - Enforce project-level guards: +auto_pick_enabled+ and quality pause.
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

      # @param candidate_source [#next_candidate] Provider-backed data
      #   access for auto-pick candidates. Defaults to the local-DB /
      #   GitHub-backed {DefaultCandidateSource}.
      def initialize(candidate_source: DefaultCandidateSource)
        @candidate_source = candidate_source
      end

      # @param context [Automation::Context]
      # @return [Automation::Result]
      # @spec ISSUE-ENHANCEMENT-013
      def evaluate(context)
        project = context.project
        return noop_result unless auto_pick_enabled?(project)
        return noop_result if project.quality_paused?

        issue = @candidate_source.next_candidate(project)
        return noop_result unless issue

        decision = if FeatureActivation.issue_auto_enhance_enabled?(project:, issue:)
          Decision.queue_analyze_issue_run(issue_id: issue.id)
        else
          Decision.queue_create_pr_run(issue_id: issue.id)
        end

        Result.new(decisions: [ decision ])
      end

      private

      def auto_pick_enabled?(project)
        Configuration::AutoPick.from_project(project).enabled?
      end
    end
  end
end
