# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundle do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:prompt_version).optional }
    it { is_expected.to belong_to(:llm_model).optional }
    it { is_expected.to have_many(:bundle_outcomes).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:configuration_bundle) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:version) }
    it { is_expected.to validate_numericality_of(:version).only_integer.is_greater_than(0) }
    it { is_expected.to validate_length_of(:strategy).is_at_most(100) }

    it "validates fingerprint uniqueness within an account" do
      bundle = create(:configuration_bundle, fingerprint: "shared-fingerprint")
      duplicate = build(:configuration_bundle, account: bundle.account, fingerprint: bundle.fingerprint)
      other_account_bundle = build(:configuration_bundle, fingerprint: bundle.fingerprint)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:fingerprint]).to be_present
      expect(other_account_bundle).to be_valid
    end

    it "validates version uniqueness scoped to account and project" do
      bundle = create(:configuration_bundle)
      duplicate = build(:configuration_bundle, account: bundle.account, project: bundle.project, version: bundle.version)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:version]).to be_present
    end

    it "prevents duplicate versions for account-level bundles (nil project)" do
      account = create(:account)
      create(:configuration_bundle, account: account, project: nil, version: 1)

      duplicate = build(:configuration_bundle, account: account, project: nil, version: 1)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:version]).to be_present
    end

    it "allows same version for different projects" do
      account = create(:account)
      project_a = create(:project, account: account)
      project_b = create(:project, account: account)
      create(:configuration_bundle, account: account, project: project_a, version: 1)

      bundle = build(:configuration_bundle, account: account, project: project_b, version: 1)
      expect(bundle).to be_valid
    end

    it "validates project belongs to account" do
      other_account = create(:account)
      project = create(:project, account: other_account)
      bundle = build(:configuration_bundle, project: project)

      expect(bundle).not_to be_valid
      expect(bundle.errors[:project]).to include("must belong to the same account")
    end

    it "allows a global prompt version for any bundle scope" do
      prompt = create(:prompt, :global)
      prompt_version = create(:prompt_version, prompt: prompt)
      project = create(:project)

      expect(build(:configuration_bundle, prompt_version: prompt_version)).to be_valid
      expect(build(:configuration_bundle, account: project.account, project: project, prompt_version: prompt_version)).to be_valid
    end

    it "requires account-scoped prompt versions to match the bundle account" do
      prompt = create(:prompt, :for_account)
      prompt_version = create(:prompt_version, prompt: prompt)
      bundle = build(:configuration_bundle, prompt_version: prompt_version)

      expect(bundle).not_to be_valid
      expect(bundle.errors[:prompt_version]).to include("must match the bundle account/project scope")
    end

    it "requires project-scoped prompt versions to match the bundle project" do
      bundle_project = create(:project)
      prompt = create(:prompt, project: create(:project, account: bundle_project.account), account: bundle_project.account)
      prompt_version = create(:prompt_version, prompt: prompt)
      bundle = build(:configuration_bundle, account: bundle_project.account, project: bundle_project, prompt_version: prompt_version)

      expect(bundle).not_to be_valid
      expect(bundle.errors[:prompt_version]).to include("must match the bundle account/project scope")
    end
  end

  describe "scopes" do
    it "filters by status" do
      draft = create(:configuration_bundle, status: "draft")
      active = create(:configuration_bundle, status: "active", activated_at: Time.current)
      retired = create(:configuration_bundle, status: "retired", retired_at: Time.current)

      expect(described_class.draft).to contain_exactly(draft)
      expect(described_class.active).to contain_exactly(active)
      expect(described_class.retired).to contain_exactly(retired)
    end
  end

  describe "#activate!" do
    it "transitions a draft bundle to active" do
      bundle = create(:configuration_bundle, status: "draft")

      bundle.activate!

      expect(bundle.status).to eq("active")
      expect(bundle.activated_at).to be_present
    end

    it "raises when not in draft status" do
      bundle = create(:configuration_bundle, status: "active", activated_at: Time.current)

      expect { bundle.activate! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#retire!" do
    it "transitions an active bundle to retired" do
      bundle = create(:configuration_bundle, status: "active", activated_at: Time.current)

      bundle.retire!

      expect(bundle.status).to eq("retired")
      expect(bundle.retired_at).to be_present
    end

    it "raises when not in active status" do
      bundle = create(:configuration_bundle, status: "draft")

      expect { bundle.retire! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#avg_quality_score" do
    it "returns the average quality score of outcomes" do
      bundle = create(:configuration_bundle)
      create(:bundle_outcome, configuration_bundle: bundle, quality_score: 0.8)
      create(:bundle_outcome, configuration_bundle: bundle, quality_score: 0.6)

      expect(bundle.avg_quality_score).to eq(0.7)
    end

    it "returns nil when no outcomes exist" do
      bundle = create(:configuration_bundle)

      expect(bundle.avg_quality_score).to be_nil
    end
  end

  describe "#success_rate" do
    it "returns the ratio of successful outcomes" do
      bundle = create(:configuration_bundle)
      create(:bundle_outcome, configuration_bundle: bundle, success: true)
      create(:bundle_outcome, configuration_bundle: bundle, success: true)
      create(:bundle_outcome, configuration_bundle: bundle, success: false)

      expect(bundle.success_rate).to be_within(0.001).of(0.667)
    end

    it "returns nil when no outcomes exist" do
      bundle = create(:configuration_bundle)

      expect(bundle.success_rate).to be_nil
    end
  end
end
