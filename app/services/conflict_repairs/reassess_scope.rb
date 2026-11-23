# frozen_string_literal: true

module ConflictRepairs
  # Produces one new, immutable decision from an automatically-produced repair artifact.
  # It performs no coding and never rewrites the producer's history.
  # @spec AUTO-MERGE-011
  class ReassessScope
    Result = Data.define(:status, :evidence, :reason) do
      def accepted? = status == :accepted
    end

    def self.call(...) = new(...).call

    def self.reassessable_producer?(agent_run)
      agent_run.automatic? && agent_run.status == "failed" && agent_run.focus == "merge_conflict" && agent_run.result_commit_sha.present?
    end

    def initialize(agent_run:, requested_by: nil)
      @agent_run = agent_run
      @requested_by = requested_by
    end

    def call
      return refused("producer_is_not_an_immutable_failed_repair") unless eligible?
      return refused("requesting_actor_not_authorized") unless requesting_actor_authorized?
      return refused("project_or_issue_paused") if paused?
      return refused("source_issue_untrusted") unless issue.trusted?
      return refused("cost_budget_exhausted") unless CostBudgets::Check.call(project, agent_run:)[:allowed]

      pr = project.client.pull_request(project.full_name, agent_run.source_pull_request_number)
      return unavailable("Provider head no longer matches the immutable artifact", pr.head.sha) unless pr.head.sha == agent_run.result_commit_sha

      existing = ConflictRepairScopeEvidence.current_for(agent_run:, head_sha: pr.head.sha, integration_base_sha: pr.base.sha)
      return Result.new(:accepted, existing, nil) if existing && existing.status != "unavailable"

      evidence = assess(pr)
      Result.new(:accepted, evidence, nil)
    rescue GithubClient::Error
      Result.new(:accepted, record("unavailable", "Provider comparison evidence was unavailable", nil, nil, agent_run.result_commit_sha), nil)
    end

    private

    attr_reader :agent_run, :requested_by

    def project = @project ||= agent_run.project.reload
    def issue = @issue ||= agent_run.issue&.reload
    def eligible? = self.class.reassessable_producer?(agent_run) && pre_run_sha.present? && issue.present?
    def paused? = project.paused? || project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused? || issue.paused?
    def pre_run_sha = agent_run.external_metadata["pre_run_head_sha"]

    def assess(pr)
      base = project.client.compare_summary(project.full_name, pre_run_sha, pr.base.sha)
      result = project.client.compare_summary(project.full_name, pre_run_sha, pr.head.sha)
      decision = AssessScope.call(agent_run:, base_comparison: base, result_comparison: result)
      # A second provider read closes both range races. Do not publish a
      # decision for a range that is no longer the provider's current base/HEAD.
      current = project.client.pull_request(project.full_name, agent_run.source_pull_request_number)
      unless current.head.sha == pr.head.sha && current.base.sha == pr.base.sha
        return record("unavailable", "Provider base or head changed during scope reassessment", nil, nil, current.head.sha, current.base.sha)
      end

      record(decision.status, decision.explanation, decision.base_imported_paths, decision.repair_authored_paths, current.head.sha, pr.base.sha)
    end

    def unavailable(message, provider_head)
      Result.new(:accepted, record("unavailable", message, [], [], provider_head), nil)
    end

    def record(status, explanation, base_paths, repair_paths, provider_head, base_sha = nil)
      attributes = { agent_run:, account: project.account, project:, issue:, requested_by:, pre_run_sha:,
        integration_base_sha: base_sha || "unavailable", result_sha: agent_run.result_commit_sha,
        provider_head_sha: provider_head, status:, explanation:, base_imported_paths: base_paths || [], repair_authored_paths: repair_paths || [] }
      ConflictRepairScopeEvidence.create_or_find_by!(attributes.slice(:agent_run, :pre_run_sha, :integration_base_sha, :result_sha, :provider_head_sha, :status)) do |evidence|
        evidence.assign_attributes(attributes)
      end
    end

    def requesting_actor_authorized?
      return false unless requested_by

      AgentRunPolicy.new(requested_by.reload, agent_run).retry?
    rescue ActiveRecord::RecordNotFound
      false
    end

    def refused(reason) = Result.new(:refused, nil, reason)
  end
end
