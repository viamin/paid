# frozen_string_literal: true

module CloseoutVerifications
  # Admits immutable merge-bound verification work. It deliberately does not
  # enqueue ProcessRunQueueJob: execution has a dedicated successor contract.
  # @spec STAGED-CLOSEOUT-ADOPTION-008 STAGED-CLOSEOUT-ADOPTION-009
  class Admit
    Outcome = Data.define(:runs, :reason) do
      def admitted? = runs.any?
    end

    def self.call(...) = new(...).call

    def initialize(source_pr:, merge_commit_sha:)
      @source_pr = source_pr
      @merge_commit_sha = merge_commit_sha.to_s
    end

    def call
      return Outcome.new([], "source_lineage_missing") unless source_pr&.is_pull_request? && source_issue
      return Outcome.new([], "merge_revision_missing") if merge_commit_sha.blank?
      return Outcome.new([], "project_inactive") unless Project.active.where(id: project.id).exists?
      return Outcome.new([], "project_paused") if paused?

      mapping_results = merged_revision_mappings.map { |mapping| eligible(mapping) }
      return Outcome.new([], no_mapping_reason(mapping_results)) if mapping_results.empty? || mapping_results.none?(&:eligible?)

      runs = mapping_results.filter_map { |result| admit(result.mapping) if result.eligible? }
      Outcome.new(runs, runs.empty? ? (@existing_reason || "already_current_result") : nil)
    end

    private

    attr_reader :merge_commit_sha, :source_pr

    def project = source_pr.project

    def source_issue
      @source_issue ||= source_pr.parent_issue || source_evidence_run&.issue
    end

    def source_evidence_run
      @source_evidence_run ||= PartialCloseouts::Assessment.latest_source_pull_request_evidence_run_for(
        project:, pull_request_number: source_pr.github_number
      )
    end

    def paused?
      project.paused? || project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused?
    end

    def merged_revision_mappings
      project.staged_closeout_mappings.where(issue: source_issue).approved.where(stage: "merged_revision").order(:id)
    end

    def eligible(mapping)
      StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project:, issue: source_issue)
    end

    def no_mapping_reason(results)
      if results.empty?
        return "live_target_unconfirmed" if live_environment_mapping?

        return "no_merged_revision_mapping"
      end

      results.map(&:reason).compact.first || "no_eligible_mapping"
    end

    def live_environment_mapping?
      project.staged_closeout_mappings.where(issue: source_issue).approved.where(stage: "live_environment").exists?
    end

    def admit(mapping)
      existing = existing_run(mapping)
      return nil if existing

      AgentRun.create!(run_attributes(mapping))
    rescue ActiveRecord::RecordNotUnique => error
      raise error unless existing_run(mapping)

      nil
    end

    def existing_run(mapping)
      run = identity_scope(mapping).first
      return unless run

      @existing_reason = run.status == "completed" ? "already_current_result" : "already_admitted"
      run
    end

    def identity_scope(mapping)
      AgentRun.where(project:, issue: source_issue, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
        source_pull_request_number: source_pr.github_number, base_commit_sha: merge_commit_sha,
        closeout_mapping_id: mapping.id)
    end

    def run_attributes(mapping)
      {
        project:, issue: source_issue, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
        status: "queued", trigger_type: "automatic", synthetic: true,
        source_pull_request_number: source_pr.github_number, base_commit_sha: merge_commit_sha,
        closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
        closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest,
        external_metadata: { "closeout_verification" => {
          "stage" => mapping.stage, "mapping_revision" => mapping.revision,
          "source_pr_number" => source_pr.github_number, "merged_commit_sha" => merge_commit_sha
        } }
      }
    end
  end
end
