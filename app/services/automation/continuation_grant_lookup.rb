# frozen_string_literal: true

module Automation
  # RDR-077 §3: a continuation grant follows the work item and its explicitly
  # linked continuation chain. The chain is the work item, the pull requests
  # Paid opened for it, and — from a pull request back to its source issue.
  #
  # It deliberately does NOT walk decomposed or explicitly linked child issues:
  # an additional issue needs its own authorization (RDR-077 §3).
  #
  # @spec AUTOMATION-PHASES-006
  module ContinuationGrantLookup
    module_function

    # Work-item issue ids in the same continuation chain. Returns [] for work
    # with no issue (a no-issue manual run cannot carry a work-item grant).
    def chain_issue_ids(work_item)
      issue = issue_for(work_item)
      return [] unless issue

      root_ids = [ issue.id ]
      root_ids << issue.parent_issue_id if issue.is_pull_request? && issue.parent_issue_id.present?

      root_ids | linked_pull_request_ids(root_ids)
    end

    # Active grants covering `phase` for the given work item.
    def resolve(project:, phase:, work_item: nil)
      return WorkItemContinuationGrant.none unless project && phase

      ids = chain_issue_ids(work_item)
      return WorkItemContinuationGrant.none if ids.empty?

      WorkItemContinuationGrant
        .active
        .where(project_id: project.id, issue_id: ids)
        .select { |grant| grant.covers_phase?(phase) }
    end

    def covering(project:, phase:, work_item: nil)
      resolve(project:, phase:, work_item:).first
    end

    # True when an operator-started manual action for this work is still
    # outstanding. This is the Inbox relevance exception: requests needed to
    # finish explicitly started work stay actionable even in a disabled phase.
    # @spec INBOX-PHASE-RELEVANCE-002
    def outstanding_manual_action?(project:, issue:)
      return false unless project && issue

      ids = chain_issue_ids(issue)
      return false if ids.empty?

      project.agent_runs
        .where(issue_id: ids, trigger_type: "manual")
        .where(status: AgentRun::UNFINISHED_STATUSES)
        .exists?
    end

    def issue_for(work_item)
      case work_item
      when Issue then work_item
      when AgentRun then run_issue(work_item)
      end
    end

    def run_issue(run)
      return run.issue if run.issue

      pull_request = run.project.issues.pull_requests_only
        .find_by(github_number: run.source_pull_request_number)
      pull_request&.parent_issue || pull_request
    end

    def linked_pull_request_ids(issue_ids)
      Issue.where(parent_issue_id: issue_ids, is_pull_request: true).pluck(:id)
    end
  end
end
