# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::Resolve do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    it "returns the current version of the resolved prompt" do
      prompt = create(:prompt, :global, slug: "coding.issue_implementation")
      version = prompt.create_version!(template: "Do the work on {{title}}")

      result = described_class.call(slug: "coding.issue_implementation", project: project)

      expect(result).to eq(version)
    end

    it "returns nil when no matching prompt exists" do
      result = described_class.call(slug: "nonexistent", project: project)

      expect(result).to be_nil
    end

    it "returns nil when prompt has no current version" do
      create(:prompt, :global, slug: "coding.no_version")

      result = described_class.call(slug: "coding.no_version", project: project)

      expect(result).to be_nil
    end

    it "resolves project-level prompt over account-level" do
      global_prompt = create(:prompt, :global, slug: "coding.test")
      global_prompt.create_version!(template: "Global")

      account_prompt = create(:prompt, account: account, slug: "coding.test")
      account_prompt.create_version!(template: "Account")

      project_prompt = create(:prompt, project: project, slug: "coding.test")
      project_version = project_prompt.create_version!(template: "Project")

      result = described_class.call(slug: "coding.test", project: project)

      expect(result).to eq(project_version)
    end
  end
end
