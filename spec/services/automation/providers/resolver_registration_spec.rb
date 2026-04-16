# frozen_string_literal: true

require "rails_helper"

# Verifies the config/initializers/automation_providers.rb initializer wires
# the GitHub-backed adapters into the provider resolver registry so policy
# code can resolve them from a Project without knowing provider details.
RSpec.describe Automation::Providers::Resolver do
  let(:project_class) do
    Class.new do
      def provider_type = nil
      def full_name = "acme/widgets"
    end
  end
  let(:project) { project_class.new }

  describe ".registered?" do
    it "reports :github as registered after boot" do
      expect(described_class.registered?(:github)).to be true
    end
  end

  describe ".repository_for" do
    it "returns a GitHub::RepositoryProvider instance" do
      expect(described_class.repository_for(project))
        .to be_a(Automation::Providers::Github::RepositoryProvider)
    end
  end

  describe ".work_item_for" do
    it "returns a GitHub::WorkItemProvider instance" do
      expect(described_class.work_item_for(project))
        .to be_a(Automation::Providers::Github::WorkItemProvider)
    end
  end

  describe ".review_for" do
    it "returns a GitHub::ReviewProvider instance" do
      expect(described_class.review_for(project))
        .to be_a(Automation::Providers::Github::ReviewProvider)
    end
  end
end
