# frozen_string_literal: true

require "rails_helper"

module Models
  module RunnerTierLookupSpec
    class AgentRunLike
      attr_reader :runner

      def initialize(runner:)
        @runner = runner
      end
    end

    class RunnerLike
      attr_reader :tier_model_ids

      def initialize(tier_model_ids:)
        @tier_model_ids = tier_model_ids
      end
    end

    class ModelLike
      attr_reader :model_id

      def initialize(model_id:)
        @model_id = model_id
      end
    end

    class ActiveScopeLike
      def find_by(model_id:)
      end
    end

    class Dummy
      include RunnerTierLookup

      attr_reader :agent_run

      def initialize(agent_run)
        @agent_run = agent_run
      end

      def lookup(tier)
        runner_tier_model(tier)
      end

      def excluded?(model, excluded)
        excluded_model?(model, excluded)
      end
    end
  end
end

RSpec.describe Models::RunnerTierLookup, :no_db do
  let(:lookup_host_class) { Models::RunnerTierLookupSpec::Dummy }

  describe "#lookup" do
    it "returns nil when no tier is requested" do
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike, runner: nil))

      expect(dummy.lookup(nil)).to be_nil
    end

    it "returns nil when the runner has no model configured for the tier" do
      runner = instance_double(Models::RunnerTierLookupSpec::RunnerLike, tier_model_ids: { "low" => "" })
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike, runner: runner))

      expect(dummy.lookup("low")).to be_nil
    end

    it "looks up the active model for the configured tier" do
      model = instance_double(Models::RunnerTierLookupSpec::ModelLike)
      active_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)
      runner = instance_double(Models::RunnerTierLookupSpec::RunnerLike, tier_model_ids: { "high" => "gpt-5.4" })
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike, runner: runner))
      fake_model_class = Class.new do
        def self.active
        end
      end

      stub_const("LlmModel", fake_model_class)
      allow(fake_model_class).to receive(:active).and_return(active_scope)
      allow(active_scope).to receive(:find_by).with(model_id: "gpt-5.4").and_return(model)

      expect(dummy.lookup("high")).to eq(model)
    end
  end

  describe "#excluded?" do
    let(:model) { instance_double(Models::RunnerTierLookupSpec::ModelLike, model_id: "gpt-5.4") }
    let(:dummy) { lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike, runner: nil)) }

    it "returns true when the model id is in the exclusion list" do
      expect(dummy.excluded?(model, %w[gpt-5.4 gpt-5.3])).to be(true)
    end

    it "returns false for non-array exclusions" do
      expect(dummy.excluded?(model, "gpt-5.4")).to be(false)
    end
  end
end
