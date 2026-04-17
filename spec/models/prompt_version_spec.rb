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

  describe "review state" do
    let(:prompt) { create(:prompt, :global) }

    it "defaults to nil review_status (not participating in review workflow)" do
      version = create(:prompt_version, prompt: prompt, version: 1)
      expect(version.review_status).to be_nil
      expect(version).not_to be_under_review
      expect(version).not_to be_pending_review
    end

    it "supports pending/approved/rejected transitions" do
      version = create(:prompt_version, :pending_review, prompt: prompt, version: 1)

      expect(version).to be_pending_review
      expect(version).to be_under_review
      expect(version).not_to be_approved

      version.update!(review_status: "approved", reviewed_at: Time.current)
      expect(version).to be_approved
      expect(version).not_to be_pending_review
    end

    it "rejects invalid review_status values" do
      version = build(:prompt_version, prompt: prompt, version: 1, review_status: "bogus")
      expect(version).not_to be_valid
      expect(version.errors[:review_status]).to be_present
    end

    it "scopes versions by review state" do
      pending = create(:prompt_version, :pending_review, prompt: prompt, version: 1)
      approved = create(:prompt_version, :approved, prompt: prompt, version: 2)
      rejected = create(:prompt_version, :rejected, prompt: prompt, version: 3)
      _unreviewed = create(:prompt_version, prompt: prompt, version: 4)

      expect(described_class.pending_review).to contain_exactly(pending)
      expect(described_class.approved).to contain_exactly(approved)
      expect(described_class.rejected).to contain_exactly(rejected)
    end

    it "allows review fields to be updated after creation" do
      version = create(:prompt_version, :pending_review, prompt: prompt, version: 1)
      user = create(:user)

      version.reviewed_by_user = user
      version.reviewed_at = Time.current
      version.review_notes = "Good enough"
      version.review_status = "approved"
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
