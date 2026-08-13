# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::RunnerAuthAttempts::Report do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:other_project) { create(:project, account: other_account) }

  before do
    # Managed Claude materialization on local Docker.
    create(:runner_auth_attempt, account: account, project: project,
      runner_key: "claude", attempt_stage: "materialization",
      auth_source: "managed", materialization_mode: "env",
      container_host: "local", backend_supports_host_paths: true, backend_remote: false,
      result: "materialized")

    # Host-forwarded Claude materialization on local Docker.
    create(:runner_auth_attempt, :host_forwarded, account: account, project: project,
      runner_key: "claude",
      attempt_stage: "materialization", auth_source: "host_forwarded",
      materialization_mode: "host_mount",
      container_host: "local", backend_supports_host_paths: true, backend_remote: false,
      result: "materialized")

    # Managed Codex that failed auth_expired.
    create(:runner_auth_attempt, :failed, account: account, project: project,
      runner_key: "codex", attempt_stage: "eligibility",
      auth_source: "managed", materialization_mode: "env",
      container_host: "remote", backend_supports_host_paths: false, backend_remote: true,
      failure_reason: "credential_expired", result: "failed")

    # Host-forwarded Codex that was rejected for host bind mount.
    create(:runner_auth_attempt, :failed, account: account, project: project,
      runner_key: "codex", attempt_stage: "eligibility",
      auth_source: "host_forwarded", materialization_mode: "host_mount",
      container_host: "remote", backend_supports_host_paths: false, backend_remote: true,
      failure_reason: "requires_host_bind_mount", result: "failed")

    # Codex refresh failure.
    create(:runner_auth_attempt, :refresh_failed, account: account, project: project,
      runner_key: "codex",
      attempt_stage: "refresh", auth_source: "host_forwarded",
      materialization_mode: "host_mount",
      container_host: "local", backend_supports_host_paths: true, backend_remote: false,
      result: "refresh_failed", failure_reason: "exchange_refresh_token_failed")

    # Unrelated tenant — must never leak into the report.
    create(:runner_auth_attempt, account: other_account, project: other_project,
      runner_key: "gemini", attempt_stage: "materialization",
      auth_source: "host_forwarded", materialization_mode: "host_mount",
      container_host: "local", result: "materialized")
  end

  describe ".call" do
    it "filters by account" do
      report = described_class.call(filters: { account_ids: [ account.id ] })

      expect(report[:summary][:total_count]).to eq(5)
      expect(report[:summary][:project_count]).to eq(1)
      expect(report[:summary][:account_count]).to eq(1)
      expect(report[:summary][:provider_count]).to eq(2)
      expect(report[:summary][:container_host_count]).to eq(2)
    end

    it "computes success and failure counts" do
      report = described_class.call(filters: { account_ids: [ account.id ] })
      summary = report[:summary]

      expect(summary[:success_count]).to eq(2)
      expect(summary[:failure_count]).to eq(3)
      expect(summary[:success_rate]).to be_within(0.001).of(0.4)
    end

    it "groups by provider and auth_source for managed vs host comparison" do
      report = described_class.call(filters: { account_ids: [ account.id ] })
      rows = report[:by_provider]

      claude_managed = rows.find { |row| row[:runner_key] == "claude" && row[:auth_source] == "managed" }
      claude_host = rows.find { |row| row[:runner_key] == "claude" && row[:auth_source] == "host_forwarded" }
      codex_managed = rows.find { |row| row[:runner_key] == "codex" && row[:auth_source] == "managed" }

      expect(claude_managed[:total_count]).to eq(1)
      expect(claude_managed[:success_count]).to eq(1)
      expect(claude_host[:total_count]).to eq(1)
      expect(claude_host[:success_count]).to eq(1)
      expect(codex_managed[:total_count]).to eq(1)
      expect(codex_managed[:failure_count]).to eq(1)
      expect(codex_managed[:success_rate]).to eq(0.0)
    end

    it "groups by container_host" do
      report = described_class.call(filters: { account_ids: [ account.id ] })
      rows = report[:by_container_host]

      local = rows.select { |row| row[:container_host] == "local" }
      remote = rows.select { |row| row[:container_host] == "remote" }

      expect(local.sum { |row| row[:total_count] }).to eq(3)
      expect(remote.sum { |row| row[:total_count] }).to eq(2)
    end

    it "breaks down failure reasons so auth_expired / refresh_failed / materialization_failed / remote-rejected are distinguishable" do
      report = described_class.call(filters: { account_ids: [ account.id ] })
      rows = report[:failure_reason_breakdown]
      reasons = rows.map { |row| row[:failure_reason] }

      expect(reasons).to include("credential_expired")
      expect(reasons).to include("requires_host_bind_mount")
      expect(reasons).to include("exchange_refresh_token_failed")
    end

    it "serializes the applied filters" do
      report = described_class.call(filters: {
        account_ids: [ account.id ],
        runner_keys: [ "claude" ],
        from: 1.day.ago,
        to: 1.day.from_now
      })

      expect(report[:filters][:account_ids]).to eq([ account.id ])
      expect(report[:filters][:runner_keys]).to eq([ "claude" ])
      expect(report[:filters][:from]).to be_present
      expect(report[:filters][:to]).to be_present
    end

    it "scopes results to projects within the requested account" do
      report = described_class.call(filters: { account_ids: [ account.id ] })
      provider_keys = report[:by_provider].map { |row| row[:runner_key] }

      expect(provider_keys).not_to include("gemini")
    end

    it "handles an empty result set without raising" do
      report = described_class.call(filters: { account_ids: [ -1 ] })
      expect(report[:summary][:total_count]).to eq(0)
      expect(report[:by_provider]).to eq([])
      expect(report[:by_container_host]).to eq([])
      expect(report[:failure_reason_breakdown]).to eq([])
    end
  end
end
