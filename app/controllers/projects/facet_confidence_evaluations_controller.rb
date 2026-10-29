# frozen_string_literal: true

module Projects
  # Reference-judgment screen and lifecycle actions for the facet-confidence
  # closeout evaluation (#4596). Thin controller: authorization through
  # FacetConfidenceEvaluationPolicy, behavior through the
  # FacetConfidence::CloseoutEvaluation services, blinding through CaseView.
  # Returns only to fixed internal paths — never an arbitrary external return
  # URL.
  # @spec FACET-CONFIDENCE-020
  # @spec FACET-CONFIDENCE-021
  class FacetConfidenceEvaluationsController < ApplicationController
    before_action :set_project
    before_action :set_evaluation, except: %i[new create]

    def new
      authorize FacetConfidenceEvaluation.new(project: @project)
      @issue = @project.issues.find(params[:issue_id])
      @packet = FacetConfidence::CloseoutEvaluationPacket.call(issue: @issue, status: Issues::CloseoutStatus.call(@issue))
      @existing = @issue.facet_confidence_evaluations.find_by(corpus_digest: @packet.corpus_digest)
      @inbox_context = inbox_context
    end

    def create
      authorize FacetConfidenceEvaluation.new(project: @project)

      issue = @project.issues.find(params[:issue_id])
      result = FacetConfidence::CloseoutEvaluation::Start.call(project: @project, issue: issue, actor: current_user)
      if result.success?
        redirect_to evaluation_path(result.evaluation),
          notice: result.resumed ? "Resumed the existing evaluation for this closeout." : "Evaluation started. Record the blinded reference judgments, then freeze the reference set."
      else
        redirect_to new_project_facet_confidence_evaluation_path(@project, issue_id: issue.id, **inbox_context), alert: result.error
      end
    end

    def show
      authorize @evaluation

      @progress = FacetConfidence::CloseoutEvaluation::CaseView.progress(@evaluation)
      @next_case_id = requested_case_id || FacetConfidence::CloseoutEvaluation::CaseView.next_pending_case_id(@evaluation)
      @case_view = FacetConfidence::CloseoutEvaluation::CaseView.new(evaluation: @evaluation, case_id: @next_case_id.to_s, actor: current_user)
      @corpus_changed = @evaluation.answers_visible? && !@evaluation.corpus.matches_recorded_digest?
      @labels = @evaluation.labels.includes(revisions: :recorded_by).index_by(&:case_id) if @evaluation.answers_visible?
      @inbox_context = inbox_context
    end

    def label
      authorize @evaluation

      result = FacetConfidence::CloseoutEvaluation::RecordLabel.call(
        evaluation: @evaluation,
        actor: current_user,
        case_id: params[:case_id].to_s,
        judgment: judgment_params
      )
      redirect_for(result, success_notice: "Reference judgment recorded.")
    end

    def skip
      authorize @evaluation

      result = FacetConfidence::CloseoutEvaluation::RecordLabel.call(
        evaluation: @evaluation,
        actor: current_user,
        case_id: params[:case_id].to_s,
        judgment: nil
      )
      redirect_for(result, success_notice: "Case skipped — it still needs a judgment before you can freeze.")
    end

    def freeze
      authorize @evaluation

      result = FacetConfidence::CloseoutEvaluation::FreezeLabels.call(evaluation: @evaluation, actor: current_user)
      redirect_for(result, success_notice: "Reference set frozen. The compiled report is ready to return to the Inbox item.")
    end

    def revise
      authorize @evaluation

      result = FacetConfidence::CloseoutEvaluation::ReviseLabel.call(
        evaluation: @evaluation, actor: current_user, case_id: params[:case_id].to_s, judgment: judgment_params
      )
      redirect_for(result, success_notice: "Correction appended; the frozen judgment and report are preserved.")
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_evaluation
      @evaluation = @project.facet_confidence_evaluations.find(params[:id])
    end

    # A case id outside the frozen corpus falls back to the next pending case
    # instead of rendering a misleading "every case is judged" screen.
    def requested_case_id
      candidate = params[:case_id].presence
      candidate if candidate && @evaluation.corpus.case_ids.include?(candidate)
    end

    def judgment_params
      {
        verdict: params[:verdict].presence,
        intent_band: params[:intent_band].presence,
        technical_band: params[:technical_band].presence,
        readiness: params[:readiness].presence,
        cited_evidence_reference: params[:cited_evidence_reference].presence,
        reason: params[:reason].presence
      }
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
      project_facet_confidence_evaluation_path(@project, evaluation, **inbox_context)
    end
  end
end
