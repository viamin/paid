# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::Request do
  # Keep this explicit rather than relying on a passing broad suite: adding a
  # text assessment requires an intentional classification in the LLD.
  let(:direct_request_caller_inventory) do
    %w[
    app/services/agent_run_patterns/diagnose.rb
    app/services/agent_runs/diagnose_error.rb
    app/services/conflict_repairs/assess_scope.rb
    app/services/design_amendments/impact_review.rb
    app/services/feature_intents/assess_design_artifact_candidates.rb
    app/services/feature_intents/assess_facet.rb
    app/services/feature_intents/criteria_clarity_review.rb
    app/services/features/clarifying_questions/analyze.rb
    app/services/intent_conformance/reviewer_llm.rb
    app/services/issues/partial_completion_assessment.rb
    app/services/knowledge/context_intake/generate_questions.rb
    app/services/knowledge/decisions/draft.rb
    app/services/models/meta_agent_selector.rb
    app/services/partial_closeouts/assess_evidence.rb
    app/services/partial_closeouts/validate_submitted_evidence.rb
    app/services/prompt_evolution/mutate.rb
    app/services/reviews/verification/llm_session.rb
    app/services/screenshots/derive_hints.rb
    app/services/strategy_evolution/mutate.rb
    app/services/style_guide_evolution/mutate.rb
    app/services/style_guides/compress.rb
    app/services/style_guides/extract.rb
    app/temporal/activities/analyze_issue_activity.rb
    app/temporal/activities/analyze_knowledge_gaps_activity.rb
    app/temporal/activities/decompose_feature_activity.rb
    ].freeze
  end

  let(:wrapped_request_caller_inventory) do
    %w[
    app/services/llm/analyze_partial_closeout.rb
    app/services/llm/generate_agent_update_summary.rb
    app/services/llm/generate_issue_title.rb
    app/services/llm/generate_pr_description.rb
    app/services/llm/generate_session_summary.rb
    app/services/partial_closeouts/reconcile_legacy.rb
    app/temporal/activities/assess_source_closure_activity.rb
    app/temporal/activities/reconcile_partial_closeout_activity.rb
    app/temporal/activities/run_acceptance_audit_activity.rb
    ].freeze
  end

  # @spec LLM-ROUTING-009
  it "keeps every non-chat application text caller in the isolated routing inventory" do
    expect(direct_request_callers).to eq(direct_request_caller_inventory)
    expect(wrapped_request_callers).to eq(wrapped_request_caller_inventory)
  end

  def direct_request_callers
    request_callers.select { |path| File.read(path).include?("Llm::Request.call") }
  end

  def wrapped_request_callers
    request_callers.select do |path|
      path.start_with?("app/services/llm/") && File.read(path).match?(/\bRequest\.call\(/) ||
        File.read(path).include?("Llm::AnalyzePartialCloseout.call")
    end
  end

  def request_callers
    Dir.glob(Rails.root.join("app/{services,temporal}/**/*.rb")).sort.map do |path|
      Pathname(path).relative_path_from(Rails.root).to_s
    end
  end
end
