# frozen_string_literal: true

module Projects
  # Operator/API surface for reviewed staged-closeout eligibility. It never
  # dispatches a check; automatic scheduling belongs to #5074.
  # @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-006 STAGED-CLOSEOUT-ADOPTION-014
  class StagedCloseoutAdoptionsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :update?
      respond_to do |format|
        format.json { render json: payload }
        format.html { prepare_review }
      end
    end

    def update
      authorize @project, :update?
      StagedCloseoutAdoption::Enroll.call(project: @project, actor: current_user, enabled: params.require(:enabled))
      respond_success(payload, notice: "Acceptance check settings updated.")
    rescue StagedCloseoutAdoption::Error => error
      respond_error(error)
    end

    def create_mapping
      authorize @project, :update?
      issue = @project.issues.find(params.require(:issue_id))
      mapping = StagedCloseoutAdoption::Mappings.approve(project: @project, actor: current_user, issue:, attributes: mapping_params)
      respond_success({ mapping: mapping.slice(*mapping_fields) }, notice: "Reviewed check saved.", status: :created)
    rescue StagedCloseoutAdoption::Error, ActiveRecord::RecordInvalid => error
      respond_error(error)
    end

    def revoke_mapping
      authorize @project, :update?
      mapping = @project.staged_closeout_mappings.find(params[:id])
      StagedCloseoutAdoption::Mappings.revoke(mapping:, project: @project, actor: current_user, issue: mapping.issue, attributes: {}).then do |record|
        respond_success({ mapping: record.slice(*mapping_fields) }, notice: "Reviewed check revoked.")
      end
    rescue StagedCloseoutAdoption::Error => error
      respond_error(error)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def payload
      data = StagedCloseoutAdoption::Projection.for_project(@project)
      return data if params[:issue_id].blank?

      issue = @project.issues.issues_only.find(params.expect(:issue_id))
      @closeout_progress = Inbox::StagedCloseoutProgress.call(issue:)
      data.merge(progress: @closeout_progress.map(&:to_h))
    end

    def mapping_fields
      StagedCloseoutAdoption::Projection::MAPPING_FIELDS
    end

    def mapping_params
      values = params.require(:mapping).permit(:criterion_key, :stage, :phase, :target_shape, :execution_path, :target_key,
        :target_reference, :review_stage, :environment_class, :freshness_seconds, retry_policy: {}).to_h
      if values.key?("target_reference")
        values["execution_path"], values["target_key"] = values.delete("target_reference").to_s.split(":", 2)
      end
      if values.key?("review_stage")
        values["stage"], values["phase"] = values.delete("review_stage").to_s.split(":", 2)
        values["target_shape"] = StagedCloseoutAdoption::Mappings::TARGET_SHAPES[values["stage"]]
      end
      values
    end

    def respond_success(body, notice:, status: :ok)
      respond_to do |format|
        format.json { render json: body, status: }
        format.html { redirect_to project_staged_closeout_adoption_path(@project), notice:, status: :see_other }
      end
    end

    def respond_error(error)
      respond_to do |format|
        format.json { render json: { error: error.message }, status: :unprocessable_entity }
        format.html do
          prepare_review
          @review_error = error.message
          render :show, status: :unprocessable_entity
        end
      end
    end

    def prepare_review
      @adoption = payload
      scope = @project.issues.issues_only
      @review_issues = scope.where(github_state: "open").or(scope.where(id: params[:issue_id])).order(:github_number)
      @review_issue = @review_issues.find_by(id: params[:issue_id])
      assessment = PartialCloseouts::Assessment.call(@review_issue) if @review_issue
      @review_criteria = assessment && !assessment.stale? ? assessment.criteria.map { |criterion| criterion.fetch("criterion") } : []
      recipes = PreCommitRequirement.resolve(project: @project).reject(&:user_level?)
      @review_targets = recipes.map { |recipe| [ recipe.name, "technical_prerequisite:#{recipe.id}" ] } +
        TrustedMeasurements::ALLOWLIST.keys.map { |key| [ key.humanize, "trusted_measurement:#{key}" ] }
    end
  end
end
