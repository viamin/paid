# frozen_string_literal: true

require "rails_helper"

module Models
  module RunnerTierLookupSpec
    class AgentRunLike
      attr_reader :runner, :project

      def initialize(runner:, project: nil)
        @runner = runner
        @project = project
      end
    end

    class RunnerLike
      attr_reader :tier_model_ids, :runner_key, :direct_outbound_llm_model_provider

      def initialize(tier_model_ids:, runner_key: nil, direct_outbound_llm_model_provider: nil, free_model_policy: false)
        @tier_model_ids = tier_model_ids
        @runner_key = runner_key
        @direct_outbound_llm_model_provider = direct_outbound_llm_model_provider
        @free_model_policy = free_model_policy
      end

      def free_model_policy?
        @free_model_policy
      end
    end

    class ModelLike
      attr_reader :model_id

      def initialize(model_id:)
        @model_id = model_id
      end
    end

    class ProjectLike
      attr_reader :llm_provider_allowlist, :llm_provider_blocklist

      def initialize(restricted: false, allowlist: [], blocklist: [])
        @llm_provider_allowlist = allowlist
        @llm_provider_blocklist = blocklist
        @restricted = restricted
      end

      def llm_provider_routing_restricted?
        @restricted
      end
    end

    class ActiveScopeLike
      def find_by(model_id:)
      end

      def by_provider(provider)
      end

      def free
      end

      def where(*)
        self
      end

      def not(*)
        self
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

      def compatible_scope(scope)
        compatible_model_scope(scope)
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

  describe "#compatible_scope" do
    let(:scope) { instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike) }
    let(:unrestricted_project) { Models::RunnerTierLookupSpec::ProjectLike.new }

    it "returns the original scope when no runner is attached" do
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike,
        runner: nil, project: unrestricted_project))

      expect(dummy.compatible_scope(scope)).to eq(scope)
    end

    it "filters by the runner's fixed direct-outbound provider when available" do
      minimax_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)
      runner = instance_double(
        Models::RunnerTierLookupSpec::RunnerLike,
        runner_key: "pi",
        tier_model_ids: {},
        direct_outbound_llm_model_provider: "minimax"
      )
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike,
        runner: runner, project: unrestricted_project))

      allow(runner).to receive(:free_model_policy?).and_return(false)
      allow(scope).to receive(:by_provider).with("minimax").and_return(minimax_scope)

      expect(dummy.compatible_scope(scope)).to eq(minimax_scope)
    end

    %w[openrouter_free opencode kilocode pi omp].each do |runner_key|
      it "constrains #{runner_key} runners in free policy mode to the free pricing tier" do
        free_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)
        runner = instance_double(
          Models::RunnerTierLookupSpec::RunnerLike,
          runner_key: runner_key,
          tier_model_ids: {},
          direct_outbound_llm_model_provider: nil
        )
        dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike,
          runner: runner, project: unrestricted_project))

        allow(runner).to receive(:free_model_policy?).and_return(true)
        allow(scope).to receive(:free).and_return(free_scope)

        expect(dummy.compatible_scope(scope)).to eq(free_scope)
      end
    end

    it "does not constrain a non-free-policy OpenCode runner to free models" do
      provider_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)
      runner = instance_double(
        Models::RunnerTierLookupSpec::RunnerLike,
        runner_key: "opencode",
        tier_model_ids: {},
        direct_outbound_llm_model_provider: "openrouter"
      )
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike,
        runner: runner, project: unrestricted_project))

      allow(runner).to receive(:free_model_policy?).and_return(false)
      allow(scope).to receive(:by_provider).with("openrouter").and_return(provider_scope)

      expect(dummy.compatible_scope(scope)).to eq(provider_scope)
    end

    it "narrows the scope to allowlisted providers when the project restricts routing" do
      allowlist_project = Models::RunnerTierLookupSpec::ProjectLike.new(
        restricted: true, allowlist: %w[anthropic]
      )
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike,
        runner: nil, project: allowlist_project))
      routed_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)

      allow(scope).to receive(:where).with(provider: %w[anthropic]).and_return(routed_scope)

      expect(dummy.compatible_scope(scope)).to eq(routed_scope)
    end

    it "excludes blocklisted providers when the project restricts routing" do
      blocklist_project = Models::RunnerTierLookupSpec::ProjectLike.new(
        restricted: true, blocklist: %w[openai]
      )
      dummy = lookup_host_class.new(instance_double(Models::RunnerTierLookupSpec::AgentRunLike,
        runner: nil, project: blocklist_project))
      routed_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)
      negated_scope = instance_double(Models::RunnerTierLookupSpec::ActiveScopeLike)

      allow(scope).to receive(:where).with(no_args).and_return(negated_scope)
      allow(negated_scope).to receive(:not).with(provider: %w[openai]).and_return(routed_scope)

      expect(dummy.compatible_scope(scope)).to eq(routed_scope)
    end
  end
end
