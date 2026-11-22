# frozen_string_literal: true

module PullRequests
  # Carries a conflict-repair scope decision from completion to every later
  # automatic-merge boundary. A matching repair run makes an assessment
  # mandatory; no matching run means this gate does not apply.
  # @spec AUTO-MERGE-010
  class ConflictRepairScopeGate
    ASSESSMENT_KEY = "conflict_repair_scope_assessment"
    Result = Data.define(:allowed, :reason_code, :agent_run_id) do
      def allowed? = allowed == true
    end

    def self.call(...) = new(...).call

    def initialize(project:, issue:, head_sha:)
      @project = project
      @issue = issue
      @head_sha = head_sha
    end

    def call
      run = applicable_run
      return Result.new(allowed: true, reason_code: nil, agent_run_id: nil) unless run

      assessment = reassessment_or_original(run)
      return blocked(run, "conflict_repair_scope_assessment_incomplete") unless valid_assessment?(assessment)
      return Result.new(allowed: true, reason_code: nil, agent_run_id: run.id) if assessment["status"] == "approved"

      blocked(run, "conflict_repair_scope_#{assessment["status"]}")
    end

    private

    attr_reader :project, :issue, :head_sha

    def applicable_run
      return if head_sha.blank?

      AgentRun.where(
        project: project,
        issue: issue,
        goal: "create_pr",
        focus: "merge_conflict",
        trigger_type: "automatic",
        source_pull_request_number: issue.github_number,
        result_commit_sha: head_sha
      ).order(created_at: :desc, id: :desc).first
    end

    def valid_assessment?(assessment)
      assessment.is_a?(Hash) &&
        assessment["head_sha"] == head_sha &&
        assessment["base_sha"].present? &&
        assessment["status"].in?(%w[approved rejected unavailable]) &&
        assessment["explanation"].present? &&
        assessment["base_imported_paths"].is_a?(Array) &&
        assessment["repair_authored_paths"].is_a?(Array)
    end

    # @spec AUTO-MERGE-011
    def reassessment_or_original(run)
      evidence = ConflictRepairScopeEvidence.current_for(agent_run: run, head_sha: head_sha)
      return evidence_to_assessment(evidence) if evidence

      run.external_metadata[ASSESSMENT_KEY]
    end

    def evidence_to_assessment(evidence)
      {
        "status" => evidence.status,
        "explanation" => evidence.explanation,
        "base_sha" => evidence.pre_run_sha,
        "integration_base_sha" => evidence.integration_base_sha,
        "head_sha" => evidence.result_sha,
        "base_imported_paths" => evidence.base_imported_paths,
        "repair_authored_paths" => evidence.repair_authored_paths
      }
    end

    def blocked(run, reason_code)
      Result.new(allowed: false, reason_code:, agent_run_id: run.id)
    end
  end
end
