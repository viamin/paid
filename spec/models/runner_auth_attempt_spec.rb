# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerAuthAttempt, type: :model do
  describe "validations" do
    it "is valid with the factory defaults" do
      expect(build(:runner_auth_attempt)).to be_valid
    end

    it "requires a runner_key" do
      record = build(:runner_auth_attempt, runner_key: nil)
      expect(record).not_to be_valid
      expect(record.errors[:runner_key]).to include("can't be blank")
    end

    it "requires an attempt_stage" do
      record = build(:runner_auth_attempt, attempt_stage: nil)
      expect(record).not_to be_valid
      expect(record.errors[:attempt_stage]).to include("can't be blank")
    end

    it "rejects an unknown attempt_stage" do
      record = build(:runner_auth_attempt, attempt_stage: "unicorn")
      expect(record).not_to be_valid
      expect(record.errors[:attempt_stage]).to include("is not included in the list")
    end

    it "rejects an unknown auth_source" do
      record = build(:runner_auth_attempt, auth_source: "moon")
      expect(record).not_to be_valid
      expect(record.errors[:auth_source]).to include("is not included in the list")
    end

    it "rejects an unknown materialization_mode" do
      record = build(:runner_auth_attempt, materialization_mode: "smoke_signal")
      expect(record).not_to be_valid
      expect(record.errors[:materialization_mode]).to include("is not included in the list")
    end

    it "requires a result" do
      record = build(:runner_auth_attempt, result: nil)
      expect(record).not_to be_valid
      expect(record.errors[:result]).to include("can't be blank")
    end

    it "auto-assigns attempted_at when missing" do
      record = build(:runner_auth_attempt, attempted_at: nil)
      record.valid?
      expect(record.attempted_at).to be_present
      expect(record.errors[:attempted_at]).to be_empty
    end

    it "rejects a negative retry_count" do
      record = build(:runner_auth_attempt, retry_count: -1)
      expect(record).not_to be_valid
      expect(record.errors[:retry_count]).to include("must be greater than or equal to 0")
    end

    it "rejects a negative duration_ms" do
      record = build(:runner_auth_attempt, duration_ms: -10)
      expect(record).not_to be_valid
      expect(record.errors[:duration_ms]).to include("must be greater than or equal to 0")
    end
  end

  describe "account/project consistency" do
    it "requires account and project to belong to the same tenant" do
      account = create(:account)
      other_project = create(:project)
      record = build(:runner_auth_attempt, account: account, project: other_project)
      expect(record).to be_valid
    end

    it "derives the project from agent_run when missing" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)
      record = build(:runner_auth_attempt, project: nil, agent_run: agent_run)
      record.valid?
      expect(record.project).to eq(project)
    end

    it "rejects mismatched project and agent_run" do
      project = create(:project)
      other_project = create(:project)
      agent_run = create(:agent_run, project: project)
      record = build(:runner_auth_attempt, project: other_project, agent_run: agent_run)
      expect(record).not_to be_valid
      expect(record.errors[:project]).to include("must match the agent run's project")
    end
  end

  describe "secret redaction" do
    it "rejects forbidden metadata keys" do
      record = build(:runner_auth_attempt, metadata: { token: "sk-ant-oat01-secret" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("forbidden key")
    end

    it "rejects metadata values that look like bearer tokens" do
      record = build(:runner_auth_attempt, metadata: { note: "sk-ant-oat01-abcdef0123456789" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("secret-shaped")
    end

    it "rejects metadata values that look like GitHub PATs" do
      record = build(:runner_auth_attempt, metadata: { trace: "ghp_abcdef0123456789abcdef0123456789abcd" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("secret-shaped")
    end

    it "rejects metadata values that look like Authorization headers" do
      record = build(:runner_auth_attempt, metadata: { trace: "Bearer eyJhbGciOi..." })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("secret-shaped")
    end

    it "rejects refresh_token metadata keys" do
      record = build(:runner_auth_attempt, metadata: { refresh_token: "rt_secret_value" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("forbidden key")
    end

    it "rejects native credentials JSON metadata" do
      record = build(:runner_auth_attempt, metadata: { native_credentials_json: "{}" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("forbidden key")
    end

    it "rejects auth_json metadata keys" do
      record = build(:runner_auth_attempt, metadata: { auth_json: "{}" })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("forbidden key")
    end

    it "rejects failure_reason values that look like a secret" do
      record = build(:runner_auth_attempt, failure_reason: "sk-ant-oat01-abcdef0123456789")
      expect(record).not_to be_valid
      expect(record.errors[:failure_reason].join).to include("non-secret")
    end

    it "rejects oversized failure_reason values" do
      record = build(:runner_auth_attempt, failure_reason: "x" * 100)
      expect(record).not_to be_valid
      expect(record.errors[:failure_reason].join).to include("non-secret")
    end

    it "accepts safe metadata" do
      record = build(:runner_auth_attempt,
        metadata: { source: "managed_env_token", rotation_risk: "server_refresh_only" })
      expect(record).to be_valid
    end

    it "stringifies nested metadata keys" do
      record = build(:runner_auth_attempt, metadata: { source: "managed_env_token", rotation_risk: "server_refresh_only" })
      record.valid?
      expect(record.metadata.keys).to all(be_a(String))
    end

    it "walks nested hashes for secret-looking values" do
      record = build(:runner_auth_attempt,
        metadata: { details: { trace: "sk-ant-oat01-abcdef0123456789" } })
      expect(record).not_to be_valid
      expect(record.errors[:metadata].join).to include("secret-shaped")
    end
  end

  describe ".secret_like?" do
    it "flags Anthropic-style bearer tokens" do
      expect(described_class.secret_like?("sk-ant-oat01-abcdefghijklmnop")).to be(true)
    end

    it "flags GitHub fine-grained PATs" do
      expect(described_class.secret_like?("ghp_abcdefghijklmnopqrstuvwxyz0123")).to be(true)
    end

    it "flags Authorization headers" do
      expect(described_class.secret_like?("Bearer abcdefghijklmnop")).to be(true)
    end

    it "does not flag benign short strings" do
      expect(described_class.secret_like?("credential_expired")).to be(false)
      expect(described_class.secret_like?("host_mount")).to be(false)
      expect(described_class.secret_like?(nil)).to be(false)
    end
  end

  describe "scopes" do
    let!(:account) { create(:account) }
    let!(:project) { create(:project, account: account) }

    it "filters by account, runner_key, auth_source, container_host, and stage" do
      create(:runner_auth_attempt, project: project, account: account,
        runner_key: "claude", auth_source: "managed", container_host: "local")
      create(:runner_auth_attempt, :host_forwarded, project: project, account: account,
        runner_key: "codex", auth_source: "host_forwarded", container_host: "remote",
        backend_supports_host_paths: false, backend_remote: true)

      scoped = described_class.for_account(account).for_runner_key("claude")
        .for_auth_source("managed").for_container_host("local").recent
      expect(scoped.count).to eq(1)
    end

    it "filters by time window" do
      create(:runner_auth_attempt, project: project, account: account, attempted_at: 2.days.ago)
      create(:runner_auth_attempt, project: project, account: account, attempted_at: 1.hour.ago)

      expect(described_class.within(from: 1.day.ago, to: Time.current).count).to eq(1)
    end

    it "returns only successful results in the successful scope" do
      create(:runner_auth_attempt, project: project, account: account, result: "materialized")
      create(:runner_auth_attempt, :failed, project: project, account: account)

      expect(described_class.successful.count).to eq(1)
    end
  end
end
