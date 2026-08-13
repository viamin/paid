# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Orchestrators::Resolver do
  around do |example|
    previous = described_class.instance_variable_get(:@registry)
    described_class.instance_variable_set(:@registry, previous&.deep_dup || {})
    example.run
  ensure
    described_class.instance_variable_set(:@registry, previous)
  end

  let(:stub_class) { Struct.new(:namespace, keyword_init: true) }
  let(:factory) { ->(config) { stub_class.new(**config) } }

  describe ".register" do
    it "registers a factory that .for invokes with configuration" do
      described_class.reset!
      described_class.register(:kubernetes, factory)

      result = described_class.for(:kubernetes, namespace: "prod")
      expect(result.namespace).to eq("prod")
    end

    it "rejects factories that do not respond to #call" do
      expect {
        described_class.register(:bad, "not-a-callable")
      }.to raise_error(ArgumentError, /must respond to #call/)
    end
  end

  describe "default registrations" do
    it "registers the built-in orchestrator adapters" do
      expect(described_class.registered_types).to include(
        :kubernetes,
        :docker_compose,
        :docker_swarm,
        :ecs
      )
    end
  end

  describe ".for" do
    before do
      described_class.reset!
      described_class.register(:docker_compose, factory)
    end

    it "raises when no orchestrator is registered for the type" do
      expect { described_class.for(:ecs) }
        .to raise_error(described_class::UnknownOrchestratorError, /ecs/)
    end

    it "resolves the registered factory" do
      expect { described_class.for(:docker_compose) }.not_to raise_error
    end
  end

  describe ".reset!" do
    it "clears a single orchestrator type when given one" do
      described_class.register(:kubernetes, factory)
      described_class.register(:docker_compose, factory)
      described_class.register(:docker_swarm, factory)
      described_class.register(:ecs, factory)

      described_class.reset!(:kubernetes)

      expect(described_class.registered_types).to contain_exactly(
        :docker_compose,
        :docker_swarm,
        :ecs
      )
    end

    it "clears every registration when called without arguments" do
      described_class.register(:kubernetes, factory)
      described_class.register(:docker_compose, factory)

      described_class.reset!

      expect(described_class.registered_types).to be_empty
    end
  end

  describe ".registered? / .registered_types" do
    before do
      described_class.reset!
      described_class.register(:kubernetes, factory)
    end

    it "reports registered types correctly" do
      expect(described_class.registered?(:kubernetes)).to be true
      expect(described_class.registered?(:ecs)).to be false
      expect(described_class.registered_types).to contain_exactly(:kubernetes)
    end
  end
end
