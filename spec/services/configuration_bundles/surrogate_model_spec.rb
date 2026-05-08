# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::SurrogateModel do
  describe "#predict" do
    def bundle_definition(goal:, token_budget:)
      {
        "schema_version" => 1,
        "goal" => goal,
        "agent_type" => "claude_code",
        "experiments" => {
          "knowledge.token_budget" => { "value" => token_budget }
        }
      }
    end

    def create_review_outcome(project:)
      review_bundle = create(:configuration_bundle,
        account: project.account,
        definition: bundle_definition(goal: "review", token_budget: 8000))
      review_run = create(:agent_run,
        :completed,
        project: project,
        issue: create(:issue, project: project),
        goal: "review",
        source_pull_request_number: 42,
        configuration_bundle: review_bundle)

      create(:bundle_outcome, configuration_bundle: review_bundle, agent_run: review_run, quality_score: 0.95)
    end

    it "materializes outcome history once across predictions" do
      scope = instance_double(ActiveRecord::Relation)
      ordered_scope = instance_double(ActiveRecord::Relation)
      limited_scope = instance_double(ActiveRecord::Relation)
      outcome_agent_run = instance_double(AgentRun, goal: "create_pr")
      bundle = instance_double(ConfigurationBundle,
        definition: { "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code" },
        fingerprint: "known-fingerprint")
      outcome = instance_double(BundleOutcome,
        configuration_bundle: bundle,
        quality_score: 0.8,
        agent_run: outcome_agent_run)
      model = described_class.new(scope: scope)

      allow(scope).to receive(:order).with(created_at: :desc).and_return(ordered_scope)
      allow(ordered_scope).to receive(:limit).with(described_class::MAX_OUTCOME_ROWS).and_return(limited_scope)
      expect(limited_scope).to receive(:each).once.and_yield(outcome)

      2.times do
        prediction = model.predict(bundle_definition: bundle.definition, fingerprint: bundle.fingerprint)
        expect(prediction.matched_outcomes).to eq(1)
      end
    end

    it "ignores outcomes collected under a different goal" do
      project = create(:project)
      create_review_outcome(project:)

      prediction = described_class.call(
        project: project,
        bundle_definition: bundle_definition(goal: "create_pr", token_budget: 8000)
      )

      expect(prediction.mean_quality_score).to eq(described_class::PRIOR_MEAN)
      expect(prediction.matched_outcomes).to eq(0)
    end
  end
end
