# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-018
# @spec CONTAINER-RUNTIME-020
RSpec.describe ProvisioningIntent do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional(true) }
    it { is_expected.to belong_to(:agent_run).optional(true) }
  end

  describe "validations" do
    subject(:intent) { build(:provisioning_intent) }

    it { is_expected.to validate_presence_of(:resource_kind) }
    it { is_expected.to validate_presence_of(:runner_type) }
    it { is_expected.to validate_presence_of(:environment) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_numericality_of(:attempt).is_greater_than_or_equal_to(0) }
  end

  describe "state predicates" do
    it "reflects the lifecycle status" do
      pending_intent = create(:provisioning_intent, status: "pending")
      created_intent = create(:provisioning_intent, status: "created", provider_resource_id: "abc")
      linked_intent = create(:provisioning_intent, status: "linked", provider_resource_id: "abc",
                                                   runner_handle: { "runner_type" => "local_docker" })
      failed_intent = create(:provisioning_intent, status: "failed")

      expect(pending_intent).to be_pending
      expect(created_intent).to be_created
      expect(linked_intent).to be_linked
      expect(failed_intent).to be_failed
    end
  end

  describe "#orphaned?" do
    it "is true when created with a resource id but no linked handle (the crash window)" do
      intent = create(:provisioning_intent, status: "created", provider_resource_id: "abc123")

      expect(intent).to be_orphaned
    end

    it "is false once the handle is linked" do
      intent = create(:provisioning_intent, status: "linked", provider_resource_id: "abc123",
                                           runner_handle: { "runner_type" => "local_docker" })

      expect(intent).not_to be_orphaned
    end

    it "is false when no resource was created" do
      intent = create(:provisioning_intent, status: "pending")

      expect(intent).not_to be_orphaned
    end
  end

  describe ".reconcileable" do
    it "returns pending and created intents but not linked/failed" do
      pending_intent = create(:provisioning_intent, status: "pending")
      created_intent = create(:provisioning_intent, status: "created", provider_resource_id: "abc")
      create(:provisioning_intent, status: "linked", provider_resource_id: "def",
                                  runner_handle: { "runner_type" => "local_docker" })
      create(:provisioning_intent, status: "failed")

      expect(described_class.reconcileable).to contain_exactly(pending_intent, created_intent)
    end
  end

  describe ".orphans" do
    it "returns created intents that carry a provider resource id" do
      orphan = create(:provisioning_intent, status: "created", provider_resource_id: "abc123")
      create(:provisioning_intent, status: "pending")
      create(:provisioning_intent, status: "created", provider_resource_id: "ghi",
                                  runner_handle: { "runner_type" => "local_docker" })
      create(:provisioning_intent, status: "linked", provider_resource_id: "def",
                                  runner_handle: { "runner_type" => "local_docker" })

      expect(described_class.orphans).to contain_exactly(orphan)
    end
  end
end
