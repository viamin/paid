# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompt do
  describe "associations" do
    it { is_expected.to belong_to(:account).optional }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:current_version).class_name("PromptVersion").optional }
    it { is_expected.to have_many(:prompt_versions).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:prompt, :global) }

    it { is_expected.to validate_presence_of(:slug) }
    it { is_expected.to validate_length_of(:slug).is_at_most(100) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:category) }
    it { is_expected.to validate_inclusion_of(:category).in_array(described_class::CATEGORIES) }

    it "validates slug format" do
      prompt = build(:prompt, :global, slug: "valid.slug-name_1")
      expect(prompt).to be_valid

      prompt = build(:prompt, :global, slug: "Invalid Slug!")
      expect(prompt).not_to be_valid
      expect(prompt.errors[:slug]).to be_present
    end

    it "validates slug uniqueness within scope" do
      create(:prompt, :global, slug: "coding.test")

      duplicate = build(:prompt, :global, slug: "coding.test")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end

    it "allows same slug at different scopes" do
      create(:prompt, :global, slug: "coding.test")
      account_prompt = build(:prompt, :for_account, slug: "coding.test")

      expect(account_prompt).to be_valid
    end

    it "validates project belongs to account" do
      account = create(:account)
      other_account = create(:account)
      project = create(:project, account: other_account)

      prompt = build(:prompt, account: account, project: project, slug: "test.prompt")
      expect(prompt).not_to be_valid
      expect(prompt.errors[:project]).to include("must belong to the same account")
    end
  end

  describe "scopes" do
    describe ".active" do
      it "returns only active prompts" do
        active = create(:prompt, :global, active: true)
        create(:prompt, :global, :inactive)

        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".by_category" do
      it "returns prompts for the given category" do
        coding = create(:prompt, :global, category: "coding")
        create(:prompt, :global, :planning)

        expect(described_class.by_category("coding")).to eq([ coding ])
      end
    end

    describe ".global" do
      it "returns prompts without account or project" do
        global = create(:prompt, :global)
        create(:prompt, :for_account)

        expect(described_class.global).to eq([ global ])
      end
    end

    describe ".for_account" do
      it "returns account-level prompts" do
        account = create(:account)
        account_prompt = create(:prompt, account: account, project: nil)
        create(:prompt, :global)

        expect(described_class.for_account(account)).to eq([ account_prompt ])
      end
    end

    describe ".for_project" do
      it "returns project-level prompts" do
        project = create(:project)
        project_prompt = create(:prompt, project: project)
        create(:prompt, :global)

        expect(described_class.for_project(project)).to eq([ project_prompt ])
      end
    end
  end

  describe "instance methods" do
    describe "#global?" do
      it "returns true when no account or project" do
        expect(build(:prompt, :global).global?).to be true
      end

      it "returns false when account is present" do
        expect(build(:prompt, :for_account).global?).to be false
      end
    end

    describe "#account_level?" do
      it "returns true when account present and no project" do
        expect(build(:prompt, :for_account).account_level?).to be true
      end

      it "returns false when global" do
        expect(build(:prompt, :global).account_level?).to be false
      end
    end

    describe "#project_level?" do
      it "returns true when project present" do
        expect(build(:prompt, :for_project).project_level?).to be true
      end

      it "returns false when global" do
        expect(build(:prompt, :global).project_level?).to be false
      end
    end

    describe "#create_version!" do
      it "creates a new version with auto-incremented version number" do
        prompt = create(:prompt, :global)

        version1 = prompt.create_version!(template: "Version 1")
        version2 = prompt.create_version!(template: "Version 2")

        expect(version1.version).to eq(1)
        expect(version2.version).to eq(2)
      end

      it "sets the current_version to the newly created version" do
        prompt = create(:prompt, :global)

        version = prompt.create_version!(template: "New version")

        expect(prompt.reload.current_version).to eq(version)
      end
    end
  end

  describe ".resolve" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "returns global prompt when no overrides exist" do
      global = create(:prompt, :global, :with_version, slug: "coding.test")

      result = described_class.resolve("coding.test", project: project)
      expect(result).to eq(global)
    end

    it "returns account prompt over global" do
      create(:prompt, :global, :with_version, slug: "coding.test")
      account_prompt = create(:prompt, :with_version, account: account, slug: "coding.test")

      result = described_class.resolve("coding.test", project: project)
      expect(result).to eq(account_prompt)
    end

    it "returns project prompt over account and global" do
      create(:prompt, :global, :with_version, slug: "coding.test")
      create(:prompt, :with_version, account: account, slug: "coding.test")
      project_prompt = create(:prompt, :with_version, project: project, slug: "coding.test")

      result = described_class.resolve("coding.test", project: project)
      expect(result).to eq(project_prompt)
    end

    it "skips inactive prompts" do
      create(:prompt, project: project, slug: "coding.test", active: false)
      global = create(:prompt, :global, :with_version, slug: "coding.test")

      result = described_class.resolve("coding.test", project: project)
      expect(result).to eq(global)
    end

    it "returns nil when no matching prompt exists" do
      result = described_class.resolve("nonexistent.prompt", project: project)
      expect(result).to be_nil
    end

    it "does not return prompts from other accounts" do
      other_account = create(:account)
      create(:prompt, :with_version, account: other_account, slug: "coding.test")

      result = described_class.resolve("coding.test", project: project)
      expect(result).to be_nil
    end

    it "does not return prompts from other projects" do
      other_project = create(:project, account: account)
      create(:prompt, :with_version, project: other_project, slug: "coding.test")

      result = described_class.resolve("coding.test", project: project)
      expect(result).to be_nil
    end
  end
end
