# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::SurrogateModel do
  describe "#predict" do
    it "materializes outcome history once across predictions" do
      scope = instance_double(ActiveRecord::Relation)
      bundle = instance_double(ConfigurationBundle,
        definition: { "schema_version" => 1, "goal" => "create_pr", "agent_type" => "claude_code" },
        fingerprint: "known-fingerprint")
      outcome = instance_double(ConfigurationBundleOutcome, configuration_bundle: bundle, quality_score: 0.8)
      model = described_class.new(scope: scope)

      expect(scope).to receive(:find_each).once.and_yield(outcome)

      2.times do
        prediction = model.predict(bundle_definition: bundle.definition, fingerprint: bundle.fingerprint)
        expect(prediction.matched_outcomes).to eq(1)
      end
    end
  end
end
