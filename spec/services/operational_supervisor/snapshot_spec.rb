# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalSupervisor::Snapshot do
  # @spec OPERATIONAL-SUPERVISOR-004
  it "defines the operational supervisor rollout guard as default-off" do
    project = create(:project)

    expect(FeatureFlags.definition(:operational_supervisor).owner).to eq("operational-supervisor")
    expect(FeatureFlags.enabled?(:operational_supervisor, project:)).to be(false)
  end

  describe ".call" do
    let(:account) { create(:account) }
    let(:now) { Time.zone.parse("2026-11-16 12:00:00") }
    let!(:enabled_project) do
      create(:project, account:, owner: "customer-owner-name", repo: "customer-repository-name")
    end
    let(:disabled_project) { create(:project, account:) }

    before do
      allow(FeatureFlags).to receive(:enabled?) do |flag, project:|
        flag == :operational_supervisor && project == enabled_project
      end
    end

    # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-004
    it "returns only allowlisted operational facts from enabled projects" do
      forbidden = create_forbidden_fixture(project: enabled_project, now:)
      create(:issue, project: disabled_project, title: "disabled repository title")

      snapshot = described_class.call(account:, now:)

      expect(snapshot.fetch(:project_ids)).to eq([ enabled_project.id ])
      expect(snapshot.to_json).not_to include(*forbidden.values)
      expect(snapshot.to_json).not_to include("disabled repository title")
      expect(snapshot.fetch(:projects)).to all(include(:project_id, :queue_depth))
      expect(snapshot.fetch(:projects).flat_map(&:keys)).not_to include(:repository_slug)
      expect(snapshot.dig(:rollups, :run_statuses)).to include("failed" => 1)
    end

    # @spec OPERATIONAL-SUPERVISOR-002
    it "counts distinct project and pull-request pairs for PR-only rework runs" do
      another_project = create(:project, account:)
      allow(FeatureFlags).to receive(:enabled?) do |flag, project:|
        flag == :operational_supervisor && project.in?([ enabled_project, another_project ])
      end
      2.times do
        create(:agent_run, :completed, project: enabled_project, issue: nil, source_pull_request_number: 42,
          created_at: now - 1.hour)
      end
      create(:agent_run, :completed, project: another_project, issue: nil, source_pull_request_number: 42,
        created_at: now - 1.hour)

      metric = described_class.call(account:, now:).fetch(:metrics)
        .find { |candidate| candidate[:key] == "rework_runs_per_pr" }

      expect(metric).to include(numerator: 3, denominator: 2, availability: "available", value: 1.5)
    end

    # @spec OPERATIONAL-SUPERVISOR-002
    it "makes metric provenance, windows, denominators, and unavailable states explicit" do
      snapshot = described_class.call(account:, now:)

      metrics = snapshot.fetch(:metrics)
      expect(metrics).to all(include(:key, :window, :inclusion_rule, :denominator, :availability))
      expect(metrics.find { |metric| metric[:key] == "cost_per_merged_pr" }).to include(
        window: { started_at: (now - described_class::WINDOW).utc.iso8601, ended_at: now.utc.iso8601 },
        denominator: 0,
        availability: "unavailable",
        value: nil
      )
      expect(metrics.map { |metric| metric[:key] }).to eq(described_class::METRIC_KEYS)
    end

    # @spec OPERATIONAL-SUPERVISOR-002
    it "bounds and deterministically orders top-N queue facts without assigning a quality judgment" do
      runs = 12.times.map do |index|
        create(:agent_run, project: enabled_project, status: "queued", queue_entered_at: now - (index + 1).minutes)
      end

      snapshot = described_class.call(account:, now:)
      queue = snapshot.fetch(:queue)

      expect(queue.fetch(:oldest).size).to eq(described_class::TOP_N)
      expect(queue.fetch(:oldest).map { |entry| entry[:agent_run_id] }).to eq(runs.last(described_class::TOP_N).reverse.map(&:id))
      expect(queue.fetch(:oldest).flat_map(&:keys)).not_to include(:judgment, :quality, :severity)
    end

    # @spec OPERATIONAL-SUPERVISOR-004
    it "returns nil when the account has no enabled project" do
      allow(FeatureFlags).to receive(:enabled?).and_return(false)

      expect(described_class.call(account:, now:)).to be_nil
    end

    # @spec OPERATIONAL-SUPERVISOR-002
    it "bounds enabled-project provenance in ascending numeric ID order" do
      additional_projects = create_list(:project, described_class::MAX_PROJECTS + 1, account:)
      allow(FeatureFlags).to receive(:enabled?).and_return(true)

      snapshot = described_class.call(account:, now:)

      expect(snapshot.fetch(:project_limit)).to eq(described_class::MAX_PROJECTS)
      expect(snapshot.fetch(:project_ids)).to eq(([ enabled_project ] + additional_projects).sort_by(&:id).first(described_class::MAX_PROJECTS).map(&:id))
    end

    def create_forbidden_fixture(project:, now:)
      forbidden = { owner: project.owner, repo: project.repo, title: "customer issue title",
                    body: "repository-authored body", prompt: "agent prompt", log: "raw execution log",
                    error: "raw exception text", secret: "sk-super-secret-token" }
      issue = create(:issue, project:, title: forbidden[:title], body: forbidden[:body])
      run = create(:agent_run, :failed, :with_metrics, project:, issue:, custom_prompt: forbidden[:prompt],
        error_message: forbidden[:error], guardrail_context: { "credential" => forbidden[:secret] }, completed_at: now - 1.hour)
      create(:agent_run_log, agent_run: run, content: forbidden[:log])
      create(:agent_run_anomaly, agent_run: run, project:, message: forbidden[:error])
      create(:token_usage, agent_run: run, metadata: { "token" => forbidden[:secret] }, created_at: now - 1.hour)
      forbidden
    end
  end
end
