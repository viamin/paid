# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::Optimizer, :no_db do
  let(:project) { Object.new }
  let(:agent_run) { Struct.new(:issue_id, :project).new(123, project) }
  let(:service) { described_class.new(agent_run: agent_run) }
  let(:exploitative) do
    described_class::Selection.new(
      fingerprint: "exploitative",
      score_inputs: described_class::ScoreInputs.new(
        predicted_objective_score: 0.82,
        predicted_quality_score: 0.82,
        uncertainty: 0.01,
        sample_count: 4,
        acquisition_score: 0.824
      )
    )
  end
  let(:exploratory) do
    described_class::Selection.new(
      fingerprint: "exploratory",
      score_inputs: described_class::ScoreInputs.new(
        predicted_objective_score: 0.72,
        predicted_quality_score: 0.72,
        uncertainty: 0.35,
        sample_count: 1,
        acquisition_score: 0.86
      )
    )
  end

  before do
    allow(service).to receive(:ranked_candidates).and_return([ exploratory, exploitative ])
  end

  it "records project context while task routing is bootstrapping" do
    allow(service).to receive(:exploration_budget_snapshot).and_return(bootstrap_snapshot)

    selection = service.select_bundle

    expect(selection.selection_mode).to eq("exploratory")
    expect(selection.selection_context).to eq("project")
  end

  it "falls back to exploitative routing when the project budget blocks exploration during bootstrap" do
    allow(service).to receive(:exploration_budget_snapshot).and_return(
      bootstrap_snapshot.merge("project" => budget_snapshot(budget: 0.25, total_runs: 4, exploratory_runs: 1, observed_share: 0.25, projected_share: 0.4, within_budget: false))
    )

    selection = service.select_bundle

    expect(selection.fingerprint).to eq("exploitative")
    expect(selection.selection_mode).to eq("exploitative")
    expect(selection.selection_context).to eq("project")
  end

  it "preserves task context when only one candidate exists and bootstrap is inactive" do
    single_candidate = described_class::Selection.new(
      fingerprint: "only_one",
      score_inputs: described_class::ScoreInputs.new(
        predicted_objective_score: 0.82,
        predicted_quality_score: 0.82,
        uncertainty: 0.01,
        sample_count: 4,
        acquisition_score: 0.824
      )
    )
    snapshot = {
      "task" => budget_snapshot(budget: 0.1, total_runs: 12, exploratory_runs: 1, observed_share: 0.083, projected_share: 0.154, within_budget: false, bootstrap_active: false, bootstrap_minimum_runs: 9),
      "project" => budget_snapshot(budget: 0.25, total_runs: 50, exploratory_runs: 5, observed_share: 0.1, projected_share: 0.118, within_budget: true)
    }
    allow(service).to receive_messages(ranked_candidates: [ single_candidate ], exploration_budget_snapshot: snapshot)

    selection = service.select_bundle

    expect(selection.selection_mode).to eq("exploitative")
    expect(selection.selection_context).to eq("task")
    expect(selection.budget_snapshot).to be_nil
  end

  it "keeps task context once task routing has enough history to enforce its own budget" do
    allow(service).to receive(:exploration_budget_snapshot).and_return(
      "task" => budget_snapshot(budget: 0.1, total_runs: 10, exploratory_runs: 1, observed_share: 0.1, projected_share: 0.1818, within_budget: false, bootstrap_active: false, bootstrap_minimum_runs: 9),
      "project" => budget_snapshot(budget: 1.0, total_runs: 10, exploratory_runs: 1, observed_share: 0.1, projected_share: 0.1818, within_budget: true)
    )

    selection = service.select_bundle

    expect(selection.fingerprint).to eq("exploitative")
    expect(selection.selection_mode).to eq("exploitative")
    expect(selection.selection_context).to eq("task")
  end

  def bootstrap_snapshot
    {
      "task" => budget_snapshot(budget: 0.1, total_runs: 0, exploratory_runs: 0, observed_share: 0.0, projected_share: 1.0, within_budget: true, bootstrap_active: true, bootstrap_minimum_runs: 9),
      "project" => budget_snapshot(budget: 1.0, total_runs: 0, exploratory_runs: 0, observed_share: 0.0, projected_share: 1.0, within_budget: true)
    }
  end

  def budget_snapshot(budget:, total_runs:, exploratory_runs:, observed_share:, projected_share:, within_budget:,
    bootstrap_active: false, bootstrap_minimum_runs: nil)
    {
      budget: budget,
      total_runs: total_runs,
      exploratory_runs: exploratory_runs,
      observed_share: observed_share,
      projected_share: projected_share,
      within_budget: within_budget,
      bootstrap_active: bootstrap_active,
      bootstrap_minimum_runs: bootstrap_minimum_runs
    }
  end
end
