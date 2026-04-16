# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Resolver do
  around do |example|
    # Specs mutate the module-level registry; snapshot it so the rest of
    # the suite is unaffected regardless of example order.
    previous = described_class.instance_variable_get(:@registry)
    described_class.instance_variable_set(:@registry, previous&.deep_dup || {})
    example.run
  ensure
    described_class.instance_variable_set(:@registry, previous)
  end

  # A real class stands in for Project. Subclasses override #provider_type
  # to exercise the resolver's configuration paths. Using a real class
  # keeps verifying-double lint satisfied without coupling the spec to
  # the full Project schema.
  let(:project_without_provider_type_class) { Class.new }
  let(:project_without_provider_type) { project_without_provider_type_class.new }

  let(:project_with_provider_type_class) do
    Class.new do
      attr_accessor :provider_type

      def initialize(provider_type)
        @provider_type = provider_type
      end
    end
  end

  let(:repo_factory) { ->(_project) { Object.new } }
  let(:work_item_factory) { ->(_project) { Object.new } }
  let(:review_factory) { ->(_project) { Object.new } }

  describe ".provider_type_for" do
    it "defaults to :github when the project does not declare a provider_type" do
      expect(described_class.provider_type_for(project_without_provider_type))
        .to eq(:github)
    end

    it "reads provider_type from the project when declared" do
      project = project_with_provider_type_class.new("gitlab")

      expect(described_class.provider_type_for(project)).to eq(:gitlab)
    end

    it "returns :github when provider_type is blank" do
      project = project_with_provider_type_class.new(nil)

      expect(described_class.provider_type_for(project)).to eq(:github)
    end
  end

  describe ".register" do
    it "registers factories that a resolve call invokes with the project" do
      described_class.reset!
      described_class.register(
        :github,
        repository: repo_factory,
        work_item: work_item_factory,
        review: review_factory
      )

      expect(repo_factory).to receive(:call).with(project_without_provider_type).and_return(:repo)
      expect(described_class.repository_for(project_without_provider_type)).to eq(:repo)
    end

    it "rejects factories that do not respond to #call" do
      expect {
        described_class.register(:github, repository: "not-a-callable")
      }.to raise_error(ArgumentError, /must respond to #call/)
    end

    it "allows partial registration and accumulates capabilities over calls" do
      described_class.reset!
      described_class.register(:github, repository: repo_factory)
      described_class.register(:github, work_item: work_item_factory)

      expect(described_class.registered?(:github)).to be true
      expect { described_class.repository_for(project_without_provider_type) }.not_to raise_error
      expect { described_class.work_item_for(project_without_provider_type) }.not_to raise_error
    end
  end

  describe ".repository_for / .work_item_for / .review_for" do
    before do
      described_class.reset!
      described_class.register(
        :github,
        repository: repo_factory,
        work_item: work_item_factory,
        review: review_factory
      )
    end

    it "raises when no providers are registered for the project's provider type" do
      project = project_with_provider_type_class.new(:gitlab)

      expect { described_class.repository_for(project) }
        .to raise_error(described_class::UnknownProviderTypeError, /gitlab/)
    end

    it "raises when the registered provider type lacks the requested capability" do
      described_class.reset!
      described_class.register(:github, repository: repo_factory)

      expect { described_class.work_item_for(project_without_provider_type) }
        .to raise_error(described_class::UnregisteredProviderError, /work_item/)
    end
  end

  describe ".reset!" do
    it "clears a single provider type when given one" do
      described_class.register(:github, repository: repo_factory)
      described_class.register(:gitlab, repository: repo_factory)

      described_class.reset!(:github)

      expect(described_class.registered_provider_types).to contain_exactly(:gitlab)
    end

    it "clears every registration when called without arguments" do
      described_class.register(:github, repository: repo_factory)
      described_class.register(:gitlab, repository: repo_factory)

      described_class.reset!

      expect(described_class.registered_provider_types).to be_empty
    end
  end

  describe "capability validation" do
    it "surfaces an error when policy code asks for an unknown capability" do
      described_class.reset!
      described_class.register(:github, repository: repo_factory)

      expect {
        described_class.send(:resolve, :not_a_capability, project_without_provider_type)
      }.to raise_error(described_class::UnknownCapabilityError)
    end
  end
end
