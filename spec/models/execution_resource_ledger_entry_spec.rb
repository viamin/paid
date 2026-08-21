# frozen_string_literal: true

require "rails_helper"

# @spec RESOURCE-LEDGER-001
# @spec RESOURCE-LEDGER-002
# @spec RESOURCE-LEDGER-003
# @spec RESOURCE-LEDGER-004
RSpec.describe ExecutionResourceLedgerEntry, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional }
  end

  describe "validations" do
    it "is valid with the factory defaults" do
      expect(build(:execution_resource_ledger_entry)).to be_valid
    end

    it "requires a runner_type" do
      record = build(:execution_resource_ledger_entry, runner_type: nil)
      expect(record).not_to be_valid
      expect(record.errors[:runner_type]).to include("can't be blank")
    end

    it "requires a resource_kind from the documented list" do
      record = build(:execution_resource_ledger_entry, resource_kind: "database")
      expect(record).not_to be_valid
      expect(record.errors[:resource_kind]).to include("is not included in the list")
    end

    it "accepts every documented resource_kind" do
      described_class::RESOURCE_KINDS.each do |kind|
        record = build(:execution_resource_ledger_entry, resource_kind: kind)
        expect(record).to be_valid, "expected #{kind} to be valid: #{record.errors.full_messages}"
      end
    end

    it "requires status to be one of the documented lifecycle states" do
      record = build(:execution_resource_ledger_entry, status: "running")
      expect(record).not_to be_valid
      expect(record.errors[:status]).to include("is not included in the list")
    end

    it "rejects negative cleanup_attempts" do
      record = build(:execution_resource_ledger_entry, cleanup_attempts: -1)
      expect(record).not_to be_valid
      expect(record.errors[:cleanup_attempts]).to include("must be greater than or equal to 0")
    end

    it "requires tags to be an object" do
      record = build(:execution_resource_ledger_entry)
      record.tags = "paid.managed=true"
      expect(record).not_to be_valid
      expect(record.errors[:tags]).to include("must be an object")
    end

    it "requires runner_handle to be an object" do
      record = build(:execution_resource_ledger_entry)
      record.runner_handle = "docker:abc123"
      expect(record).not_to be_valid
      expect(record.errors[:runner_handle]).to include("must be an object")
    end
  end

  describe "account/project/run consistency (tenant scoping)" do
    it "rejects an account that belongs to a different tenant than the project" do
      account = create(:account)
      other_project = create(:project)
      record = build(:execution_resource_ledger_entry, account: account, project: other_project)
      expect(record).not_to be_valid
      expect(record.errors[:account]).to include("must match the project's account")
    end

    it "derives the account from the project when missing" do
      project = create(:project)
      record = build(:execution_resource_ledger_entry, account: nil, project: project)
      record.valid?
      expect(record.account).to eq(project.account)
    end

    it "rejects mismatched project and agent_run" do
      project = create(:project)
      other_project = create(:project)
      agent_run = create(:agent_run, project: project)
      record = build(:execution_resource_ledger_entry, project: other_project, agent_run: agent_run, account: other_project.account)
      expect(record).not_to be_valid
      expect(record.errors[:project]).to include("must match the agent run's project")
    end
  end

  describe "secret-free tags" do
    it "rejects forbidden tag keys" do
      record = build(:execution_resource_ledger_entry, tags: { token: "sk-ant-oat01-secret" })
      expect(record).not_to be_valid
      expect(record.errors[:tags].join).to include("forbidden key")
    end

    it "rejects tag values that look like secrets" do
      github_pat = "ghp_" + ("a" * 36)
      record = build(:execution_resource_ledger_entry, tags: { "paid.note" => github_pat })
      expect(record).not_to be_valid
      expect(record.errors[:tags].join).to include("secret-shaped")
    end

    it "walks nested tag structures for secret-looking values" do
      record = build(:execution_resource_ledger_entry, tags: { "paid.details" => { "trace" => "Bearer abcdef123456" } })
      expect(record).not_to be_valid
      expect(record.errors[:tags].join).to include("secret-shaped")
    end

    it "stringifies nested tag keys" do
      record = build(:execution_resource_ledger_entry, tags: { "paid.managed" => "true", nested: { ok: true } })
      record.valid?
      expect(record.tags.keys).to all(be_a(String))
    end

    it "accepts safe tags" do
      record = build(:execution_resource_ledger_entry, tags: { "paid.managed" => "true", "paid.account_id" => "42" })
      expect(record).to be_valid
    end

    it "cannot be bypassed by the normal constructor when tags carry raw credential material" do
      expect {
        described_class.create!(
          project: create(:project),
          runner_type: "docker",
          resource_kind: "primary_environment",
          tags: { api_key: "sk-ant-oat01-should-not-persist" }
        )
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(described_class.count).to eq(0)
    end
  end

  describe "status predicates" do
    it "reflects the persisted status" do
      expect(build(:execution_resource_ledger_entry, status: "provisioning")).to be_provisioning
      expect(build(:execution_resource_ledger_entry, status: "active")).to be_active
      expect(build(:execution_resource_ledger_entry, status: "cleanup_pending")).to be_cleanup_pending
      expect(build(:execution_resource_ledger_entry, status: "deleted")).to be_deleted
      expect(build(:execution_resource_ledger_entry, status: "orphaned")).to be_orphaned
      expect(build(:execution_resource_ledger_entry, status: "cleanup_failed")).to be_cleanup_failed
    end
  end

  describe "status transitions" do
    it "rejects an illegal direct status update" do
      record = create(:execution_resource_ledger_entry, status: "provisioning")
      record.status = "deleted"
      expect(record).not_to be_valid
      expect(record.errors[:status]).to include("cannot transition from provisioning to deleted")
    end

    it "allows a documented direct status update" do
      record = create(:execution_resource_ledger_entry, status: "provisioning")
      record.status = "active"
      record.activated_at = Time.current
      expect(record).to be_valid
    end

    describe "#activate!" do
      it "transitions provisioning to active and stamps activated_at" do
        record = create(:execution_resource_ledger_entry, status: "provisioning")
        record.activate!(provider_resource_id: "cont_123")
        expect(record).to be_active
        expect(record.activated_at).to be_present
        expect(record.provider_resource_id).to eq("cont_123")
      end

      it "is idempotent when called twice" do
        record = create(:execution_resource_ledger_entry, status: "provisioning")
        record.activate!
        first_activated_at = record.activated_at
        record.activate!
        expect(record.activated_at).to eq(first_activated_at)
      end
    end

    describe "#request_cleanup!" do
      it "transitions active to cleanup_pending and stamps cleanup_requested_at" do
        record = create(:execution_resource_ledger_entry, :active)
        record.request_cleanup!
        expect(record).to be_cleanup_pending
        expect(record.cleanup_requested_at).to be_present
      end

      it "is idempotent when called twice" do
        record = create(:execution_resource_ledger_entry, :active)
        record.request_cleanup!
        first_requested_at = record.cleanup_requested_at
        record.request_cleanup!
        expect(record.cleanup_requested_at).to eq(first_requested_at)
      end
    end

    describe "#mark_deleted!" do
      it "transitions cleanup_pending to deleted and stamps deleted_at" do
        record = create(:execution_resource_ledger_entry, :cleanup_pending)
        record.mark_deleted!
        expect(record).to be_deleted
        expect(record.deleted_at).to be_present
      end

      it "is idempotent when called twice" do
        record = create(:execution_resource_ledger_entry, :cleanup_pending)
        record.mark_deleted!
        first_deleted_at = record.deleted_at
        record.mark_deleted!
        expect(record.deleted_at).to eq(first_deleted_at)
      end
    end

    describe "#mark_orphaned!" do
      it "transitions active to orphaned and stamps orphaned_at" do
        record = create(:execution_resource_ledger_entry, :active)
        record.mark_orphaned!
        expect(record).to be_orphaned
        expect(record.orphaned_at).to be_present
      end
    end

    describe "#record_cleanup_failure!" do
      it "transitions cleanup_pending to cleanup_failed and increments cleanup_attempts" do
        record = create(:execution_resource_ledger_entry, :cleanup_pending)
        record.record_cleanup_failure!(error: "provider timeout")
        expect(record).to be_cleanup_failed
        expect(record.cleanup_attempts).to eq(1)
        expect(record.cleanup_last_error).to eq("provider timeout")
        expect(record.cleanup_failed_at).to be_present
      end

      it "requires an error message" do
        record = create(:execution_resource_ledger_entry, :cleanup_pending)
        expect { record.record_cleanup_failure!(error: "") }.to raise_error(ArgumentError)
      end

      it "can be retried back into cleanup_pending" do
        record = create(:execution_resource_ledger_entry, :cleanup_failed)
        record.request_cleanup!
        expect(record).to be_cleanup_pending
      end
    end

    it "rejects transitions out of the terminal deleted state" do
      record = create(:execution_resource_ledger_entry, :deleted)
      record.status = "active"
      expect(record).not_to be_valid
      expect(record.errors[:status]).to include("cannot transition from deleted to active")
    end
  end

  describe "scopes" do
    let!(:account) { create(:account) }
    let!(:project) { create(:project, account: account) }
    let!(:agent_run) { create(:agent_run, project: project) }

    it "is queryable by account" do
      create(:execution_resource_ledger_entry, account: account, project: project)
      create(:execution_resource_ledger_entry)
      expect(described_class.for_account(account).count).to eq(1)
    end

    it "is queryable by project" do
      create(:execution_resource_ledger_entry, account: account, project: project)
      create(:execution_resource_ledger_entry)
      expect(described_class.for_project(project).count).to eq(1)
    end

    it "is queryable by agent run" do
      create(:execution_resource_ledger_entry, :with_agent_run, account: account, project: project, agent_run: agent_run)
      create(:execution_resource_ledger_entry, account: account, project: project)
      expect(described_class.for_agent_run(agent_run).count).to eq(1)
    end

    it "is queryable by resource kind" do
      create(:execution_resource_ledger_entry, :sidecar, account: account, project: project)
      create(:execution_resource_ledger_entry, account: account, project: project)
      expect(described_class.of_kind("sidecar").count).to eq(1)
    end

    it "filters live resources to non-terminal statuses" do
      create(:execution_resource_ledger_entry, :active, account: account, project: project)
      create(:execution_resource_ledger_entry, :deleted, account: account, project: project)
      expect(described_class.live.count).to eq(1)
    end
  end
end
