# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunAnomaly do
  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    subject(:agent_run_anomaly) { build(:agent_run_anomaly) }

    it { is_expected.to validate_presence_of(:anomaly_type) }
    it { is_expected.to validate_inclusion_of(:anomaly_type).in_array(described_class::ANOMALY_TYPES) }
    it { is_expected.to validate_presence_of(:severity) }
    it { is_expected.to validate_inclusion_of(:severity).in_array(described_class::SEVERITIES) }
    it { is_expected.to validate_presence_of(:metric_name) }
    it { is_expected.to validate_inclusion_of(:metric_name).in_array(ProjectBaseline::METRIC_NAMES) }
    it { is_expected.to validate_uniqueness_of(:metric_name).scoped_to(:agent_run_id) }
  end

  describe "factory" do
    it "uses the agent run project when callers override only the agent run" do
      agent_run = create(:agent_run, :completed, :with_metrics)

      anomaly = build(:agent_run_anomaly, agent_run: agent_run)

      expect(anomaly.project).to eq(agent_run.project)
      expect(anomaly).to be_valid
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }
    let(:run) { create(:agent_run, :completed, :with_metrics, project: project) }

    it ".warnings returns only warning severity" do
      warning = create(:agent_run_anomaly, agent_run: run, project: project, severity: "warning", metric_name: "tokens_total")
      create(:agent_run_anomaly, agent_run: run, project: project, severity: "critical", metric_name: "duration_seconds")

      expect(described_class.warnings).to contain_exactly(warning)
    end

    it ".critical returns only critical severity" do
      create(:agent_run_anomaly, agent_run: run, project: project, severity: "warning", metric_name: "tokens_total")
      critical = create(:agent_run_anomaly, agent_run: run, project: project, severity: "critical", metric_name: "duration_seconds")

      expect(described_class.critical).to contain_exactly(critical)
    end

    it ".recent returns anomalies from the last 24 hours" do
      recent = create(:agent_run_anomaly, agent_run: run, project: project, metric_name: "tokens_total")
      create(:agent_run_anomaly, agent_run: run, project: project, metric_name: "duration_seconds", created_at: 2.days.ago)

      expect(described_class.recent).to contain_exactly(recent)
    end
  end
end
