# frozen_string_literal: true

module PullRequests
  # Repairs interrupted PR publication closeout from unique, project-local
  # evidence. It deliberately repairs linkage only; missing labels are
  # ambiguous because an operator may have removed them intentionally.
  class RecoverMissingLinkage
    WINDOW = 7.days
    LIMIT = 500

    def self.call = new.call

    # @spec PR-LABEL-RECOVERY-003
    def call
      unlinked_prs.group_by(&:parent_issue_id).each_value do |pull_requests|
        recover(pull_requests.sole) if pull_requests.one?
      end
    end

    private

    def recover(pull_request)
      runs = unlinked_runs_for(pull_request)
      link(runs.sole, pull_request) if runs.one?
    end

    def unlinked_prs
      Issue.pull_requests_only.local_repository
        .where(github_state: "open", github_created_at: WINDOW.ago..)
        .where.not(parent_issue_id: nil)
        .where(missing_link_sql)
        .order(github_created_at: :desc)
        .limit(LIMIT)
        .to_a
    end

    def missing_link_sql
      "NOT EXISTS (SELECT 1 FROM agent_runs WHERE agent_runs.project_id = issues.project_id " \
        "AND agent_runs.pull_request_number = issues.github_number)"
    end

    def unlinked_runs_for(pull_request)
      AgentRun.finished
        .where(project_id: pull_request.project_id, issue_id: pull_request.parent_issue_id, goal: "create_pr")
        .where(pull_request_number: nil, updated_at: WINDOW.ago..)
        .order(updated_at: :desc)
        .limit(2)
        .to_a
    end

    def link(agent_run, pull_request)
      agent_run.with_lock do
        return if agent_run.pull_request_number.present?

        agent_run.update!(link_attributes(agent_run, pull_request))
      end
    end

    def link_attributes(agent_run, pull_request)
      {
        pull_request_number: pull_request.github_number,
        pull_request_url: pull_request.github_html_url,
        reconciliation: agent_run.reconciliation.merge("pull_request_link_recovered" => true)
      }
    end
  end
end
