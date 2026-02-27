# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptVersion do
  describe "associations" do
    it { is_expected.to belong_to(:prompt) }
    it { is_expected.to belong_to(:created_by_user).class_name("User").optional }
    it { is_expected.to belong_to(:parent_version).class_name("PromptVersion").optional }
    it { is_expected.to have_many(:agent_runs).dependent(:nullify) }
  end

  describe "validations" do
    subject { build(:prompt_version) }

    it { is_expected.to validate_presence_of(:version) }
    it { is_expected.to validate_numericality_of(:version).only_integer.is_greater_than(0) }
    it { is_expected.to validate_presence_of(:template) }

    it "validates version uniqueness within prompt" do
      prompt = create(:prompt, :global)
      create(:prompt_version, prompt: prompt, version: 1)

      duplicate = build(:prompt_version, prompt: prompt, version: 1)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:version]).to be_present
    end

    it "allows same version number on different prompts" do
      prompt1 = create(:prompt, :global, slug: "test.one")
      prompt2 = create(:prompt, :global, slug: "test.two")

      create(:prompt_version, prompt: prompt1, version: 1)
      version2 = build(:prompt_version, prompt: prompt2, version: 1)

      expect(version2).to be_valid
    end
  end

  describe "immutability" do
    it "prevents content field updates after creation" do
      prompt = create(:prompt, :global)
      version = create(:prompt_version, prompt: prompt, version: 1)

      version.template = "Updated template"
      expect(version).not_to be_valid
      expect(version.errors[:base]).to include("prompt version content fields are immutable after creation")
    end

    it "allows metric field updates after creation" do
      prompt = create(:prompt, :global)
      version = create(:prompt_version, prompt: prompt, version: 1)

      version.usage_count = 10
      expect(version).to be_valid
    end
  end

  describe "#render" do
    it "interpolates variables into the template" do
      version = build(:prompt_version, template: "Fix **{{title}}** (\#{{number}})\n\n{{body}}")

      result = version.render(title: "Bug in login", number: 42, body: "Login fails")

      expect(result).to eq("Fix **Bug in login** (#42)\n\nLogin fails")
    end

    it "leaves unmatched placeholders as-is" do
      version = build(:prompt_version, template: "Hello {{name}}, welcome to {{place}}")

      result = version.render(name: "Alice")

      expect(result).to eq("Hello Alice, welcome to {{place}}")
    end

    it "returns template unchanged when no variables provided" do
      version = build(:prompt_version, template: "Static template")

      expect(version.render).to eq("Static template")
    end
  end
end
