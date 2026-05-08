# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::DecompositionService do
  let(:title) { "User notification system" }
  let(:description) { "Build a full notification system." }
  let(:account) { nil }

  describe ".call" do
    subject(:result) do
      described_class.call(
        title: title,
        description: description,
        sub_components: sub_components,
        account: account
      )
    end

    context "with multiple components spanning layers" do
      let(:sub_components) { %w[database models service\ layer api\ endpoints views] }

      it "returns a valid decomposed plan" do
        expect(result).to be_valid
        expect(result).to be_decomposed
        expect(result).not_to be_skipped
        expect(result.task_count).to be > 1
      end

      it "reports the policy source" do
        expect(result.policy_source).to be_present
      end

      it "includes the applied policy" do
        expect(result.policy_applied).to include("max_tasks", "enabled")
      end

      it "produces tasks with expected structure" do
        expect(result.tasks).to all(include(:title, :description, :scope, :deps, :index))
      end
    end

    context "with a single component below threshold" do
      let(:sub_components) { %w[models] }

      it "skips decomposition" do
        expect(result).to be_skipped
        expect(result).not_to be_decomposed
        expect(result.skip_reason).to eq("below_complexity_threshold")
        expect(result.task_count).to eq(0)
      end

      it "is still valid" do
        expect(result).to be_valid
      end
    end

    context "with empty components" do
      let(:sub_components) { [] }

      it "skips decomposition" do
        expect(result).to be_skipped
        expect(result.skip_reason).to eq("below_complexity_threshold")
      end
    end

    context "with exactly the threshold number of components" do
      let(:sub_components) { %w[database service\ layer] }

      it "decomposes" do
        expect(result).not_to be_skipped
        expect(result).to be_decomposed
      end
    end

    context "with a policy that disables decomposition" do
      let(:sub_components) { %w[database models service\ layer views] }

      let(:account) { create(:account) }

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account,
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.merge(
            "decomposition" => { "enabled" => false }
          ))
      end

      it "skips decomposition" do
        expect(result).to be_skipped
        expect(result.skip_reason).to eq("decomposition_disabled_by_policy")
      end
    end

    context "with a policy that raises the complexity threshold" do
      let(:sub_components) { %w[database models] }

      let(:account) { create(:account) }

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account,
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.merge(
            "decomposition" => { "min_components_to_decompose" => 5 }
          ))
      end

      it "skips decomposition when below the custom threshold" do
        expect(result).to be_skipped
        expect(result.skip_reason).to eq("below_complexity_threshold")
      end
    end

    context "with a policy using top-level config keys" do
      let(:sub_components) { %w[database models] }

      let(:account) { create(:account) }

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account,
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.merge(
            "decomposition_enabled" => false
          ))
      end

      it "reads decomposition_enabled from top-level config" do
        expect(result).to be_skipped
        expect(result.skip_reason).to eq("decomposition_disabled_by_policy")
      end
    end

    context "with a database-backed strategy" do
      let(:sub_components) { %w[database models service\ layer] }
      let(:account) { create(:account) }

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account)
      end

      it "reports database as policy source" do
        expect(result.policy_source).to eq("database")
      end
    end

    context "with policy overrides for max_tasks and layer_order" do
      let(:sub_components) { %w[database service\ layer api\ endpoints views] }
      let(:account) { create(:account) }

      before do
        create(:orchestration_strategy, :feature_orchestration, :with_account,
          account: account,
          configuration: OrchestrationStrategies::Defaults.feature_orchestration.merge(
            "decomposition" => {
              "max_tasks" => 2,
              "layer_order" => %w[view controller service model]
            }
          ))
      end

      it "passes the effective max_tasks into the generator output" do
        expect(result.task_count).to eq(2)
      end

      it "passes the effective layer_order into the generator output" do
        expect(result.tasks.map { |task| task[:scope] }).to eq(%w[view controller])
      end
    end

    context "with no strategy record (defaults fallback)" do
      let(:sub_components) { %w[database models service\ layer] }

      it "reports defaults as policy source" do
        expect(result.policy_source).to eq("defaults")
      end
    end

    context "when strategy resolution raises an error" do
      let(:sub_components) { %w[database models service\ layer] }

      before do
        allow(OrchestrationStrategies::Resolve).to receive(:call).and_raise(StandardError, "oops")
      end

      it "falls back to default policy and still produces a result" do
        expect(result).to be_valid
        expect(result).to be_decomposed
        expect(result.policy_source).to eq("fallback")
      end
    end
  end
end
