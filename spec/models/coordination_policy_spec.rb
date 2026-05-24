# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicy do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:current_version).class_name("CoordinationPolicyVersion").optional }
    it { is_expected.to have_many(:coordination_policy_versions).dependent(:destroy) }
  end

  describe "validations" do
    subject(:coordination_policy) { build(:coordination_policy, account: account) }

    let(:account) { create(:account) }

    it { is_expected.to validate_presence_of(:policy_type) }
    it { is_expected.to validate_inclusion_of(:policy_type).in_array(described_class::POLICY_TYPES) }
    it { is_expected.to validate_presence_of(:policy_key) }
    it { is_expected.to validate_length_of(:policy_key).is_at_most(100) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "rejects duplicate account-wide policy keys within a policy type" do
      create(:coordination_policy, account: coordination_policy.account, policy_type: coordination_policy.policy_type, policy_key: coordination_policy.policy_key)

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:policy_key]).to include("has already been taken")
    end

    it "rejects duplicate project-scoped policy keys within the same project and policy type" do
      project = create(:project, account: account)
      create(:coordination_policy, :project_scoped, account: account, project:, policy_type: coordination_policy.policy_type, policy_key: coordination_policy.policy_key)

      coordination_policy.project = project

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:policy_key]).to include("has already been taken")
    end

    it "rejects a project from another account" do
      coordination_policy.project = create(:project)

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:project]).to include("must belong to the same account")
    end

    it "rejects a current version from another policy" do
      coordination_policy.current_version = create(:coordination_policy_version)

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:current_version]).to include("must belong to this coordination policy")
    end

    it "rejects an active policy whose current version is not active" do
      coordination_policy.status = "active"
      coordination_policy.current_version = build(:coordination_policy_version, coordination_policy:, status: "draft")

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:current_version]).to include("must be active before it can become current on an active policy")
    end

    it "rejects a review-gated current version that is still pending approval" do
      coordination_policy.current_version = build(:coordination_policy_version, coordination_policy:, status: "active", metadata: {
        "evolution" => {
          "approval" => {
            "required" => true,
            "status" => "pending_review"
          }
        }
      })
      coordination_policy.status = "active"

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:current_version]).to include("must be approved before it can become active")
    end

    it "rejects an inactive policy that still points at an active current version" do
      active_version = create(:coordination_policy_version, :active, coordination_policy: coordination_policy)
      coordination_policy.current_version = active_version

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:status]).to include("must be active when current_version is active")
    end

    it "derives the account from the project when omitted" do
      project = create(:project)
      coordination_policy = build(:coordination_policy, account: nil, project:)

      expect(coordination_policy).to be_valid
      expect(coordination_policy.account).to eq(project.account)
    end

    it "requires context_selector to be a hash" do
      coordination_policy.context_selector = []

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:context_selector]).to include("must be a JSON object")
    end

    it "requires metadata to be a hash" do
      coordination_policy.metadata = []

      expect(coordination_policy).not_to be_valid
      expect(coordination_policy.errors[:metadata]).to include("must be a JSON object")
    end

    it "accepts execution policies for runtime governance controls" do
      coordination_policy.policy_type = "execution"

      expect(coordination_policy).to be_valid
    end
  end

  describe "#create_version!" do
    it "creates policy versions with auto-incremented version numbers" do
      policy = create(:coordination_policy)

      version1 = policy.create_version!(rules: { "mode" => "linear" })
      version2 = policy.create_version!(rules: { "mode" => "parallel" })

      expect(version1.version).to eq(1)
      expect(version2.version).to eq(2)
    end

    it "ignores caller-supplied version values" do
      policy = create(:coordination_policy)

      version = policy.create_version!(rules: { "mode" => "parallel" }, version: 99)

      expect(version.version).to eq(1)
    end
  end

  describe "#activate_version!" do
    it "rejects a version from another policy" do
      policy = create(:coordination_policy)
      other_version = create(:coordination_policy_version)

      expect {
        policy.activate_version!(other_version)
      }.to raise_error(ArgumentError, "policy_version must belong to this coordination policy")
    end

    it "promotes the requested version and supersedes the prior active version" do
      policy = create(:coordination_policy)
      previous_version = create(:coordination_policy_version, :active, coordination_policy: policy, version: 1)
      next_version = create(:coordination_policy_version, coordination_policy: policy, version: 2)

      policy.update!(current_version: previous_version, status: "active")

      freeze_time do
        policy.activate_version!(next_version)

        expect(policy.reload.current_version).to eq(next_version)
        expect(policy.status).to eq("active")
        expect(previous_version.reload.status).to eq("superseded")
        expect(previous_version.retired_at).to eq(Time.current)
        expect(next_version.reload.status).to eq("active")
        expect(next_version.activated_at).to eq(Time.current)
      end
    end

    it "refuses to activate a review-gated version until approved" do
      policy = create(:coordination_policy)
      pending_review_version = create(:coordination_policy_version, coordination_policy: policy, version: 1, metadata: {
        "evolution" => {
          "approval" => {
            "required" => true,
            "status" => "pending_review"
          }
        }
      })

      expect {
        policy.activate_version!(pending_review_version)
      }.to raise_error(CoordinationPolicyVersion::InvalidTransitionError, "cannot activate version pending review approval")
    end
  end
end
