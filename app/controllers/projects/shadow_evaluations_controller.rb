# frozen_string_literal: true

module Projects
  # Labeling screen and lifecycle actions for the solo-maintainer RDR-067
  # shadow evaluation (#4594). Thin controller: authorization through
  # IntentConformanceShadowEvaluationPolicy, behavior through the
  # ShadowEvaluation services, blinding through CaseView. Returns only to
  # fixed internal paths — never an arbitrary external return URL.
  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  # @spec INTENT-CONFORMANCE-ROLLOUT-009
  class ShadowEvaluationsController < ApplicationController
    before_action :set_project
    before_action :set_evaluation, except: %i[new create]

    def new
      authorize IntentConformanceShadowEvaluation.new(project: @project)
      @purpose = params[:purpose].presence || default_purpose
      @existing = latest_evaluation
      @inbox_context = inbox_context
    end

    def create
      authorize IntentConformanceShadowEvaluation.new(project: @project)

      result = IntentConformance::ShadowEvaluation::Start.call(
        project: @project,
        actor: current_user,
        purpose: params[:purpose].presence || default_purpose,
        policy: params[:policy].to_s,
        manifest_path: params[:manifest_path].to_s.strip,
        manifest_commit: params[:manifest_commit].presence
      )
      if result.success?
        redirect_to evaluation_path(result.evaluation), notice: result.resumed ? "Resumed the existing evaluation for this evidence generation." : "Solo-maintainer evaluation started. Labels stay blinded until you freeze the reference set."
      else
        redirect_to new_project_shadow_evaluation_path(@project, purpose: params[:purpose].presence, **inbox_context), alert: result.error
      end
    end

    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    def show
      authorize @evaluation

      @progress = IntentConformance::ShadowEvaluation::CaseView.progress(@evaluation)
      @next_case_id = params[:case_id].presence || IntentConformance::ShadowEvaluation::CaseView.next_pending_case_id(@evaluation)
      @case_view = IntentConformance::ShadowEvaluation::CaseView.new(evaluation: @evaluation, case_id: @next_case_id.to_s, actor: current_user)
      @corpus_changed = @evaluation.answers_visible? && !@evaluation.corpus.matches_recorded_digest?
      @inbox_context = inbox_context
    end

    def label
      authorize @evaluation

      result = IntentConformance::ShadowEvaluation::RecordLabel.call(
        evaluation: @evaluation,
        actor: current_user,
        case_id: params[:case_id].to_s,
        outcome: params[:outcome].presence,
        cited_design_claim: params[:cited_design_claim],
        reason: params[:reason]
      )
      redirect_for(result, success_notice: "Label recorded.")
    end

    def skip
      authorize @evaluation

      result = IntentConformance::ShadowEvaluation::RecordLabel.call(
        evaluation: @evaluation,
        actor: current_user,
        case_id: params[:case_id].to_s,
        outcome: nil
      )
      redirect_for(result, success_notice: "Case skipped — it still needs a label before you can freeze.")
    end

    def freeze
      authorize @evaluation

      result = IntentConformance::ShadowEvaluation::FreezeLabels.call(evaluation: @evaluation, actor: current_user)
      redirect_for(result, success_notice: "Reference labels frozen. You can now execute the reviewer.")
    end

    # Runs the documented end-to-end execution path — the same service as
    # `bin/rails "intent_conformance:shadow_evaluation:execute[<id>]"`.
    def execute
      authorize @evaluation

      result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: @evaluation)
      if result.success?
        IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: @evaluation)
        redirect_to evaluation_path(@evaluation),
          notice: "Reviewer executed: #{result.executed} evaluated, #{result.failed} not evaluated."
      else
        redirect_to evaluation_path(@evaluation), alert: result.error
      end
    end

    def revise
      authorize @evaluation

      result = IntentConformance::ShadowEvaluation::ReviseLabel.call(
        evaluation: @evaluation,
        actor: current_user,
        case_id: params[:case_id].to_s,
        revised_outcome: params[:revised_outcome],
        reason: params[:reason]
      )
      IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: @evaluation) if result.success? && @evaluation.runs.exists?
      redirect_for(result, success_notice: "Revision appended — the original label is preserved.")
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_evaluation
      @evaluation = @project.intent_conformance_shadow_evaluations.find(params[:id])
    end

    def default_purpose
      "rdr-067-measured-rollout"
    end

    def latest_evaluation
      @project.intent_conformance_shadow_evaluations.where(purpose: params[:purpose].presence || default_purpose).latest_first.first
    end

    def redirect_for(result, success_notice:)
      if result.success?
        redirect_to evaluation_path(@evaluation), notice: success_notice
      else
        redirect_to evaluation_path(@evaluation), alert: result.error
      end
    end

    # Inbox context is a fixed internal route, not a caller-provided return
    # URL. Project comes from the authorized evaluation route; filters are
    # whitelisted by the Inbox's own vocabulary.
    def inbox_context
      {
        inbox_kind: params[:inbox_kind].presence_in(Inbox::Queue::KINDS),
        inbox_sort: params[:inbox_sort].presence_in(Inbox::Queue::SORTS.keys),
        inbox_entry_id: valid_inbox_entry_id
      }.compact
    end

    def valid_inbox_entry_id
      entry_id = params[:inbox_entry_id].to_s
      return if entry_id.blank?

      entry = Inbox::Queue.find_entry(user: current_user, entry_id: entry_id, project: @project,
        kind: params[:inbox_kind].presence_in(Inbox::Queue::KINDS))
      entry&.id
    end

    def evaluation_path(evaluation)
      project_shadow_evaluation_path(@project, evaluation, **inbox_context)
    end
  end
end
