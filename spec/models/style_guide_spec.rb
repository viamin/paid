# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuide do
  describe "associations" do
    it { is_expected.to belong_to(:account).optional }
    it { is_expected.to belong_to(:project).optional }
  end

  describe "validations" do
    subject { build(:style_guide, :global) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:raw_content) }
    it { is_expected.to validate_inclusion_of(:language).in_array(described_class::LANGUAGES).allow_nil }

    it "validates name uniqueness within scope" do
      create(:style_guide, :global, name: "Ruby Guide")

      duplicate = build(:style_guide, :global, name: "Ruby Guide")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "allows same name at different scopes" do
      create(:style_guide, :global, name: "Ruby Guide")
      account_guide = build(:style_guide, :for_account, name: "Ruby Guide")

      expect(account_guide).to be_valid
    end

    it "auto-sets account from project when account is nil" do
      project = create(:project)
      guide = build(:style_guide, project: project, account: nil, name: "Test Guide")

      expect(guide).to be_valid
      expect(guide.account).to eq(project.account)
    end

    it "validates project belongs to account" do
      account = create(:account)
      other_account = create(:account)
      project = create(:project, account: other_account)

      guide = build(:style_guide, account: account, project: project, name: "Test Guide")
      expect(guide).not_to be_valid
      expect(guide.errors[:project]).to include("must belong to the same account")
    end
  end

  describe "scopes" do
    describe ".active" do
      it "returns only active style guides" do
        active = create(:style_guide, :global, active: true)
        create(:style_guide, :global, :inactive)

        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".global" do
      it "returns style guides without account or project" do
        global = create(:style_guide, :global)
        create(:style_guide, :for_account)

        expect(described_class.global).to eq([ global ])
      end
    end

    describe ".for_account" do
      it "returns account-level style guides" do
        account = create(:account)
        account_guide = create(:style_guide, account: account, project: nil)
        create(:style_guide, :global)

        expect(described_class.for_account(account)).to eq([ account_guide ])
      end
    end

    describe ".for_project" do
      it "returns project-level style guides" do
        project = create(:project)
        project_guide = create(:style_guide, project: project)
        create(:style_guide, :global)

        expect(described_class.for_project(project)).to eq([ project_guide ])
      end
    end

    describe ".by_language" do
      it "returns style guides for the given language" do
        ruby_guide = create(:style_guide, :global, :with_language)
        create(:style_guide, :global, language: "python")

        expect(described_class.by_language("ruby")).to eq([ ruby_guide ])
      end
    end

    describe ".compressed" do
      it "returns style guides with compressed content" do
        compressed = create(:style_guide, :global, :compressed)
        create(:style_guide, :global)

        expect(described_class.compressed).to eq([ compressed ])
      end
    end
  end

  describe "instance methods" do
    describe "#global?" do
      it "returns true when no account or project" do
        expect(build(:style_guide, :global).global?).to be true
      end

      it "returns false when account is present" do
        expect(build(:style_guide, :for_account).global?).to be false
      end
    end

    describe "#account_level?" do
      it "returns true when account present and no project" do
        expect(build(:style_guide, :for_account).account_level?).to be true
      end

      it "returns false when global" do
        expect(build(:style_guide, :global).account_level?).to be false
      end
    end

    describe "#project_level?" do
      it "returns true when project present" do
        expect(build(:style_guide, :for_project).project_level?).to be true
      end

      it "returns false when global" do
        expect(build(:style_guide, :global).project_level?).to be false
      end
    end

    describe "#compressed?" do
      it "returns true when compressed content is present" do
        guide = build(:style_guide, :global, :compressed)
        expect(guide.compressed?).to be true
      end

      it "returns false when no compressed content" do
        guide = build(:style_guide, :global)
        expect(guide.compressed?).to be false
      end
    end

    describe "#content_for_prompt" do
      it "returns compressed content when available" do
        guide = build(:style_guide, :global, :compressed)
        expect(guide.content_for_prompt).to eq(guide.compressed_content)
      end

      it "falls back to raw content when not compressed" do
        guide = build(:style_guide, :global)
        expect(guide.content_for_prompt).to eq(guide.raw_content)
      end
    end
  end

  describe ".resolve_for" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "returns global style guides when no overrides exist" do
      global = create(:style_guide, :global)

      result = described_class.resolve_for(project)
      expect(result).to include(global)
    end

    it "returns style guides ordered by specificity" do
      global = create(:style_guide, :global)
      account_guide = create(:style_guide, account: account)
      project_guide = create(:style_guide, project: project)

      result = described_class.resolve_for(project)
      expect(result.to_a).to eq([ project_guide, account_guide, global ])
    end

    it "skips inactive style guides" do
      create(:style_guide, project: project, active: false)
      global = create(:style_guide, :global)

      result = described_class.resolve_for(project)
      expect(result).to eq([ global ])
    end

    it "does not return style guides from other accounts" do
      other_account = create(:account)
      create(:style_guide, account: other_account)

      result = described_class.resolve_for(project)
      expect(result).to be_empty
    end

    it "does not return style guides from other projects" do
      other_project = create(:project, account: account)
      create(:style_guide, project: other_project)

      result = described_class.resolve_for(project)
      expect(result).to be_empty
    end
  end
end
