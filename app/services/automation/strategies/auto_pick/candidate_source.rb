# frozen_string_literal: true

module Automation
  module Strategies
    class AutoPick
      # Work-item-provider seam for the auto-pick strategy.
      #
      # {AutoPick} (the policy) depends on a +CandidateSource+ for every
      # data-access operation it needs — filtering a project's issues to the
      # auto-pickable set, ordering them by priority/unblock/tree signals,
      # and answering "is this issue eligible?" questions surfaced in the
      # UI. Keeping those operations behind this seam lets the strategy stay
      # pure policy while still reusing the existing Postgres queries that
      # back Paid's GitHub-centric implementation.
      #
      # The default implementation — {Default} — reads the local {::Issue},
      # {::AgentRun}, and {::IssueDependency} tables. Future work-item
      # providers (Linear, Jira, ...) are expected to supply their own
      # candidate source with the same interface so the policy layer keeps
      # working unchanged.
      module CandidateSource
        # Returns the Set of issue ids from +displayed_issues+ that are
        # eligible for auto-picking, applying per-issue eligibility rules
        # only (no project-level guards such as PR attention limits or
        # active agent runs elsewhere).
        def eligible_issue_ids(displayed_issues)
          raise NotImplementedError, "#{self.class} must implement #eligible_issue_ids"
        end

        # Returns an ActiveRecord::Relation of currently eligible issues
        # for +project+. Callers typically chain ordering before taking
        # the first record.
        def eligible_scope(project)
          raise NotImplementedError, "#{self.class} must implement #eligible_scope"
        end

        # Returns the next eligible issue for +project+, already ordered by
        # the strategy's prioritization rules, or +nil+ if no candidate is
        # available.
        def next_candidate(project)
          raise NotImplementedError, "#{self.class} must implement #next_candidate"
        end
      end
    end
  end
end
