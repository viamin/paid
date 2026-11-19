# frozen_string_literal: true

module CloseoutVerifications
  # Admits reviewed live-environment checks only after the trusted environment
  # signal names the target. A merge is intentionally not an input here.
  # @spec STAGED-CLOSEOUT-ADOPTION-012
  class AdmitLiveTarget
    IDENTITY_INDEX = "index_agent_runs_live_closeout_verification_identity".freeze

    Outcome = Data.define(:runs, :reason) do
      def admitted? = runs.any?
    end

    def self.call(...) = new(...).call

    def initialize(project:, target_revision: TrustedMeasurements::DeploymentSignal.current, mapping_ids: nil)
      @project = project
      @target_revision = target_revision.to_s
      @mapping_ids = mapping_ids
    end

    def call
      return Outcome.new([], "live_target_unconfirmed") if target_revision.blank?
      return Outcome.new([], "project_inactive") unless Project.active.where(id: project.id).exists?
      return Outcome.new([], "project_paused") if paused?

      reviewed = mappings.to_a
      return Outcome.new([], "no_live_environment_mapping") if reviewed.empty?

      results = reviewed.map { |mapping| eligibility(mapping) }
      runs = results.filter_map { |result| admit(result.mapping) if result.eligible? }
      Outcome.new(runs, runs.empty? ? (results.map(&:reason).compact.first || "already_current_result") : nil)
    end

    private

    attr_reader :project, :target_revision, :mapping_ids

    def mappings
      scope = project.staged_closeout_mappings.approved.where(stage: "live_environment").includes(:issue)
      scope = scope.where(id: mapping_ids) unless mapping_ids.nil?
      scope.order(:id)
    end

    def paused? = project.paused? || project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused?

    def eligibility(mapping)
      result = StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project:, issue: mapping.issue,
        observed_target: "live_environment")
      return result unless result.eligible?
      return result if mapping.environment_class == Rails.env.to_s

      StagedCloseoutAdoption::Mappings::Result.new(mapping, "environment_class_mismatch")
    end

    def admit(mapping)
      return if existing_run(mapping)

      AgentRun.transaction do
        run = AgentRun.create!(attributes_for(mapping))
        CloseoutVerificationJob.perform_later(run.id)
        run
      end
    rescue ActiveRecord::RecordNotUnique => error
      raise unless error.message.include?(IDENTITY_INDEX) || existing_run(mapping)
    end

    def existing_run(mapping)
      run = AgentRun.where(project:, issue: mapping.issue, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
        closeout_criterion_key: mapping.criterion_key, closeout_recipe_version: mapping.target_version,
        closeout_environment: mapping.environment_class, closeout_target_revision: target_revision).first
      CloseoutVerificationJob.perform_later(run.id) if run&.status == "queued"
      run
    end

    def attributes_for(mapping)
      {
        project:, issue: mapping.issue, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
        status: "queued", trigger_type: "automatic", synthetic: true,
        branch_name: "closeout-live-target-#{SecureRandom.hex(6)}", closeout_mapping_id: mapping.id,
        closeout_criterion_key: mapping.criterion_key, closeout_recipe_version: mapping.target_version,
        closeout_recipe_digest: mapping.target_digest, closeout_environment: mapping.environment_class,
        closeout_target_revision: target_revision,
        external_metadata: { "closeout_verification" => {
          "stage" => mapping.stage, "mapping_revision" => mapping.revision,
          "environment" => mapping.environment_class, "target_revision" => target_revision
        } }
      }
    end
  end
end
