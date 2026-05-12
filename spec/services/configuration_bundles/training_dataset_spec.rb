# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::TrainingDataset do
  let(:project) { create(:project) }

  describe "#build query shape", :no_db do
    it "orders by the bundle outcome timestamp using a qualified column" do
      scope = instance_double(ActiveRecord::Relation)
      preloaded_scope = instance_double(ActiveRecord::Relation)
      limited_scope = instance_double(ActiveRecord::Relation)

      allow(scope).to receive(:preload).with(:configuration_bundle, agent_run: :project).and_return(preloaded_scope)
      allow(preloaded_scope).to receive(:order)
        .with(BundleOutcome.arel_table[:created_at].desc)
        .and_return(preloaded_scope)
      allow(preloaded_scope).to receive(:limit).with(described_class::MAX_ROWS).and_return(limited_scope)
      allow(limited_scope).to receive(:each)

      described_class.call(scope: scope)

      expect(scope).to have_received(:preload).with(:configuration_bundle, agent_run: :project)
      expect(preloaded_scope).to have_received(:order).with(BundleOutcome.arel_table[:created_at].desc)
      expect(preloaded_scope).to have_received(:limit).with(described_class::MAX_ROWS)
    end
  end

  def build_outcome_row(overrides = {})
    quality_score = overrides.fetch(:quality_score, 0.8)
    cost_cents = overrides.fetch(:cost_cents, 40)
    definition = overrides.fetch(:definition, {
      "schema_version" => 1,
      "goal" => "create_pr",
      "agent_type" => "claude_code",
      "experiments" => { "knowledge.token_budget" => { "value" => 4000 } }
    })
    success = overrides.fetch(:success, true)
    created_at = overrides.fetch(:created_at, Time.current)

    bundle = create(:configuration_bundle, account: project.account, definition: definition)
    run = create(:agent_run,
      :completed,
      project: project,
      issue: create(:issue, project: project),
      goal: definition["goal"],
      configuration_bundle: bundle,
      cost_cents: cost_cents)
    outcome = create(:bundle_outcome,
      configuration_bundle: bundle,
      agent_run: run,
      quality_score: quality_score,
      cost_cents: cost_cents,
      success: success)
    outcome.update_column(:created_at, created_at)
    outcome
  end

  describe "#build" do
    it "builds a dataset with rows extracted from bundle outcomes" do
      build_outcome_row(quality_score: 0.85)

      scope = BundleOutcome.joins(:configuration_bundle, :agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)

      dataset = described_class.call(scope: scope)

      expect(dataset.size).to eq(1)
      expect(dataset.rows.first.quality_score).to eq(0.85)
      expect(dataset.rows.first.features).to be_a(ConfigurationBundles::FeatureExtractor::FeatureVector)
    end

    it "collects experiment feature names across all rows" do
      build_outcome_row(definition: {
        "schema_version" => 1,
        "goal" => "create_pr",
        "agent_type" => "claude_code",
        "experiments" => { "knowledge.token_budget" => { "value" => 4000 } }
      })
      build_outcome_row(definition: {
        "schema_version" => 1,
        "goal" => "create_pr",
        "agent_type" => "claude_code",
        "experiments" => { "max_iterations" => { "value" => 10 } }
      })

      scope = BundleOutcome.joins(:configuration_bundle, :agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)

      dataset = described_class.call(scope: scope)

      expect(dataset.feature_names).to eq(%w[knowledge.token_budget max_iterations])
      expect(dataset.size).to eq(2)
    end

    it "assigns higher weight to more recent outcomes" do
      build_outcome_row(quality_score: 0.7, created_at: 60.days.ago)
      build_outcome_row(quality_score: 0.9, created_at: 1.hour.ago)

      scope = BundleOutcome.joins(:configuration_bundle, :agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)

      dataset = described_class.call(scope: scope)

      recent = dataset.rows.find { |r| r.quality_score == 0.9 }
      old = dataset.rows.find { |r| r.quality_score == 0.7 }
      expect(recent.weight).to be > old.weight
    end

    it "computes objective score from stored metrics when available" do
      build_outcome_row
      BundleOutcome.last.update!(metrics: { "objective_score" => 0.72 })

      scope = BundleOutcome.joins(:configuration_bundle, :agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)

      dataset = described_class.call(scope: scope)

      expect(dataset.rows.first.objective_score).to eq(0.72)
    end

    it "skips outcomes with missing bundle definitions" do
      bundle = create(:configuration_bundle, account: project.account)
      bundle.update_column(:definition, [])
      run = create(:agent_run,
        :completed,
        project: project,
        issue: create(:issue, project: project),
        configuration_bundle: bundle)
      create(:bundle_outcome,
        configuration_bundle: bundle,
        agent_run: run,
        quality_score: 0.8)

      build_outcome_row(quality_score: 0.9)

      scope = BundleOutcome.joins(:configuration_bundle, :agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)

      dataset = described_class.call(scope: scope)

      expect(dataset.size).to eq(1)
      expect(dataset.rows.first.quality_score).to eq(0.9)
    end

    it "returns an empty dataset when no outcomes match" do
      scope = BundleOutcome.joins(:configuration_bundle, :agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)

      dataset = described_class.call(scope: scope)

      expect(dataset.size).to eq(0)
      expect(dataset.rows).to eq([])
      expect(dataset.feature_names).to eq([])
    end
  end
end
