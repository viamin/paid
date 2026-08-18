# frozen_string_literal: true

require "rails_helper"

# @spec EXECUTION-AUDIT-001
# @spec EXECUTION-AUDIT-002
# @spec EXECUTION-AUDIT-003
RSpec.describe ExecutionAuditEvent, type: :model do
  describe "validations" do
    it "is valid with the factory defaults" do
      expect(build(:execution_audit_event)).to be_valid
    end

    it "requires an event_name" do
      record = build(:execution_audit_event, event_name: nil)
      expect(record).not_to be_valid
      expect(record.errors[:event_name]).to include("can't be blank")
    end

    it "rejects an event_name that isn't namespaced" do
      record = build(:execution_audit_event, event_name: "provisioned")
      expect(record).not_to be_valid
      expect(record.errors[:event_name]).to include("is invalid")
    end

    it "requires an event_version" do
      record = build(:execution_audit_event, event_version: nil)
      expect(record).not_to be_valid
      expect(record.errors[:event_version]).to include("can't be blank")
    end

    it "rejects an event_version below 1" do
      record = build(:execution_audit_event, event_version: 0)
      expect(record).not_to be_valid
      expect(record.errors[:event_version]).to include("must be greater than or equal to 1")
    end

    it "auto-assigns occurred_at when missing" do
      record = build(:execution_audit_event, occurred_at: nil)
      record.valid?
      expect(record.occurred_at).to be_present
    end

    it "rejects an unsupported credential class" do
      record = build(:execution_audit_event, credential_classes: [ "root_access" ])
      expect(record).not_to be_valid
      expect(record.errors[:credential_classes].join).to include("unsupported")
    end

    it "accepts every documented credential class" do
      record = build(:execution_audit_event, credential_classes: described_class::CREDENTIAL_CLASSES)
      expect(record).to be_valid
    end

    it "requires network_policy to be an object" do
      record = build(:execution_audit_event)
      record.network_policy = "proxy_restricted"
      expect(record).not_to be_valid
      expect(record.errors[:network_policy]).to include("must be an object")
    end

    it "rejects forbidden keys in network_policy" do
      record = build(:execution_audit_event, network_policy: { token: "sk-ant-oat01-secret" })
      expect(record).not_to be_valid
      expect(record.errors[:network_policy].join).to include("forbidden key")
    end

    it "rejects network_policy values that look like secrets" do
      record = build(:execution_audit_event, network_policy: { allow_destinations: [ "ghp_abcdef0123456789abcdef0123456789abcd" ] })
      expect(record).not_to be_valid
      expect(record.errors[:network_policy].join).to include("secret-shaped")
    end
  end

  describe "account/project/run consistency (tenant scoping)" do
    it "rejects an account that belongs to a different tenant than the project" do
      account = create(:account)
      other_project = create(:project)
      record = build(:execution_audit_event, account: account, project: other_project)
      expect(record).not_to be_valid
      expect(record.errors[:account]).to include("must match the project's account")
    end

    it "derives the project from agent_run when missing" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)
      record = build(:execution_audit_event, project: nil, agent_run: agent_run, account: project.account)
      record.valid?
      expect(record.project).to eq(project)
    end

    it "derives the account from the resolved project when missing" do
      project = create(:project)
      record = build(:execution_audit_event, account: nil, project: project)
      record.valid?
      expect(record.account).to eq(project.account)
    end

    it "rejects mismatched project and agent_run" do
      project = create(:project)
      other_project = create(:project)
      agent_run = create(:agent_run, project: project)
      record = build(:execution_audit_event, project: other_project, agent_run: agent_run, account: other_project.account)
      expect(record).not_to be_valid
      expect(record.errors[:project]).to include("must match the agent run's project")
    end
  end

  describe "secret redaction" do
    it "rejects forbidden metadata keys" do
      record = build(:execution_audit_event, metadata: { token: "sk-ant-oat01-secret" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("forbidden key")
    end

    it "rejects metadata values that look like bearer tokens" do
      record = build(:execution_audit_event, metadata: { note: "sk-ant-oat01-abcdef0123456789" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("secret-shaped")
    end

    it "walks nested hashes for secret-looking values" do
      record = build(:execution_audit_event, metadata: { details: { trace: "ghp_abcdef0123456789abcdef0123456789abcd" } })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("secret-shaped")
    end

    it "stringifies nested metadata keys" do
      record = build(:execution_audit_event, metadata: { source: "provision", nested: { ok: true } })
      record.valid?
      expect(record.metadata.keys).to all(be_a(String))
    end

    it "accepts safe metadata" do
      record = build(:execution_audit_event, metadata: { source: "provision", worktree_path: "/workspace/repo" })
      expect(record).to be_valid
    end

    %i[actor_id runner_key backend image_reference image_digest resource_id correlation_id].each do |attribute|
      it "rejects a secret-shaped value in #{attribute}" do
        record = build(:execution_audit_event, attribute => "sk-ant-oat01-abcdef0123456789")
        expect(record).not_to be_valid
        expect(record.errors[attribute]).to include("must not contain a secret-shaped value")
      end
    end

    it "cannot be bypassed by the normal constructor when metadata carries raw credential material" do
      expect {
        described_class.create!(
          account: create(:account),
          event_name: "credential.materialized",
          metadata: { access_token: "sk-ant-oat01-should-not-persist" }
        )
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(described_class.count).to eq(0)
    end
  end

  describe "scopes" do
    let!(:account) { create(:account) }
    let!(:project) { create(:project, account: account) }
    let!(:agent_run) { create(:agent_run, project: project) }

    it "is queryable by account" do
      create(:execution_audit_event, account: account, project: project)
      create(:execution_audit_event)
      expect(described_class.for_account(account).count).to eq(1)
    end

    it "is queryable by project" do
      create(:execution_audit_event, account: account, project: project)
      create(:execution_audit_event)
      expect(described_class.for_project(project).count).to eq(1)
    end

    it "is queryable by agent run" do
      create(:execution_audit_event, :with_agent_run, account: account, project: project, agent_run: agent_run)
      create(:execution_audit_event, account: account, project: project)
      expect(described_class.for_agent_run(agent_run).count).to eq(1)
    end

    it "is queryable by runner_key" do
      create(:execution_audit_event, account: account, project: project, runner_key: "codex")
      create(:execution_audit_event, account: account, project: project, runner_key: "claude")
      expect(described_class.for_runner_key("codex").count).to eq(1)
    end

    it "is queryable by image_reference" do
      create(:execution_audit_event, account: account, project: project, image_reference: "paid-agent:elixir")
      create(:execution_audit_event, account: account, project: project, image_reference: "paid-agent:latest")
      expect(described_class.for_image_reference("paid-agent:elixir").count).to eq(1)
    end

    it "is queryable by resource type and id" do
      create(:execution_audit_event, account: account, project: project, resource_type: "container", resource_id: "abc123")
      create(:execution_audit_event, account: account, project: project, resource_type: "workspace_volume", resource_id: "abc123")
      expect(described_class.for_resource("container", "abc123").count).to eq(1)
    end

    it "is queryable by correlation_id" do
      create(:execution_audit_event, account: account, project: project, correlation_id: "wf-abc")
      create(:execution_audit_event, account: account, project: project, correlation_id: "wf-xyz")
      expect(described_class.for_correlation_id("wf-abc").count).to eq(1)
    end

    it "orders recent events by occurred_at descending" do
      older = create(:execution_audit_event, account: account, project: project, occurred_at: 2.days.ago)
      newer = create(:execution_audit_event, account: account, project: project, occurred_at: 1.hour.ago)
      expect(described_class.recent.pluck(:id)).to eq([ newer.id, older.id ])
    end
  end

  describe ".record!" do
    it "creates a valid event" do
      account = create(:account)
      event = described_class.record!(account: account, event_name: "network_policy.applied", event_version: 1)
      expect(event).to be_persisted
    end
  end
end
