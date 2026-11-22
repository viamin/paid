# frozen_string_literal: true

require "rails_helper"
require "prism"

RSpec.describe Llm::Request do
  # Keep this explicit rather than relying on a passing broad suite: adding a
  # text assessment requires an intentional classification in the LLD.
  let(:direct_request_caller_inventory) do
    %w[
    app/services/agent_run_patterns/diagnose.rb
    app/services/agent_runs/diagnose_error.rb
    app/services/conflict_repairs/assess_scope.rb
    app/services/cycle_analyses/analyze.rb
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
    app/temporal/activities/assess_followup_review_threads_activity.rb
    app/temporal/activities/decompose_feature_activity.rb
    ].freeze
  end

  let(:wrapped_request_caller_inventory) do
    %w[
    app/services/knowledge/session_summaries/capture.rb
    app/services/llm/analyze_partial_closeout.rb
    app/services/llm/assess_no_output_disposition.rb
    app/services/llm/generate_agent_update_summary.rb
    app/services/llm/generate_issue_title.rb
    app/services/llm/generate_pr_description.rb
    app/services/llm/generate_session_summary.rb
    app/services/partial_closeouts/reconcile_legacy.rb
    app/temporal/activities/assess_source_closure_activity.rb
    app/temporal/activities/complete_existing_pr_run_activity.rb
    app/temporal/activities/create_github_issue_activity.rb
    app/temporal/activities/create_pull_request_activity.rb
    app/temporal/activities/handle_no_output_issue_run_activity.rb
    app/temporal/activities/reconcile_partial_closeout_activity.rb
    app/temporal/activities/run_acceptance_audit_activity.rb
    ].freeze
  end

  let(:parsed_node_cache) { {} }
  let(:source_cache) { {} }

  # @spec LLM-ROUTING-009
  it "keeps every non-chat application text caller in the isolated routing inventory" do
    expect(direct_request_callers).to match_array(direct_request_caller_inventory)
    expect(wrapped_request_callers).to match_array(wrapped_request_caller_inventory)
  end

  def direct_request_callers
    request_callers.select do |path|
      source(path).include?("Llm::Request") && constant_references(path).include?("Llm::Request")
    end
  end

  def wrapped_request_callers
    (request_wrappers.keys + wrapper_consumers).uniq.sort
  end

  def wrapper_consumers
    wrappers = request_wrappers.values
    request_callers.select do |path|
      wrappers.any? { |wrapper| source(path).include?(wrapper) } && call_receivers(path).intersect?(wrappers)
    end
  end

  def request_wrappers
    request_callers.select { |path| path.start_with?("app/services/llm/") }
      .select { |path| source(path).include?("Request.call") }
      .select { |path| call_receivers(path).include?("Request") }
      .to_h { |path| [ path, "Llm::#{File.basename(path, ".rb").camelize}" ] }
  end

  def constant_references(path)
    syntax_nodes(path, Prism::ConstantPathNode, Prism::ConstantReadNode).map(&:slice)
  end

  def call_receivers(path)
    syntax_nodes(path, Prism::CallNode).select { |node| node.name == :call }.filter_map { |node| node.receiver&.slice }
  end

  def syntax_nodes(path, *types)
    parsed_nodes(path).select { |node| types.include?(node.class) }
  end

  def parsed_nodes(path)
    parsed_node_cache[path] ||= begin
      result = Prism.parse_file(path)
      raise result.errors.map(&:message).join(", ") unless result.success?

      nodes = [ result.value ]
      nodes.each { |node| nodes.concat(node.compact_child_nodes) }
    end
  end

  def source(path)
    source_cache[path] ||= File.read(path)
  end

  def request_callers
    Dir.glob(Rails.root.join("app/{services,temporal}/**/*.rb")).sort.map do |path|
      Pathname(path).relative_path_from(Rails.root).to_s
    end
  end
end
