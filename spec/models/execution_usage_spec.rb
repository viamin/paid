# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExecutionUsage do
  let(:agent_run) { create(:agent_run, :completed) }

  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
  end

  describe "validations" do
    subject { build(:execution_usage, agent_run: agent_run) }

    it { is_expected.to validate_presence_of(:runner_backend) }
    it { is_expected.to validate_presence_of(:provisioned_at) }
    it { is_expected.to validate_presence_of(:terminated_at) }
    it { is_expected.to validate_presence_of(:termination_reason) }
    it { is_expected.to validate_inclusion_of(:termination_reason).in_array(described_class::TERMINATION_REASONS) }
    it { is_expected.to validate_length_of(:runner_backend).is_at_most(64) }
    it { is_expected.to validate_length_of(:provider_resource_id).is_at_most(255) }
    it { is_expected.to validate_numericality_of(:billed_duration_seconds).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:infra_cost_cents).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:rate_cents_per_hour).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:requested_cpu_cores).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:requested_memory_mib).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:requested_disk_gb).is_greater_than_or_equal_to(0).allow_nil }

    it "rejects terminated_at before provisioned_at" do
      usage = build(:execution_usage,
        agent_run: agent_run,
        provisioned_at: 1.hour.ago,
        terminated_at: 2.hours.ago)

      expect(usage).not_to be_valid
      expect(usage.errors[:terminated_at]).to be_present
    end

    it "accepts terminated_at equal to provisioned_at" do
      usage = build(:execution_usage,
        agent_run: agent_run,
        provisioned_at: Time.current,
        terminated_at: Time.current)

      expect(usage).to be_valid
    end
  end

  describe "scopes" do
    let!(:local_run) { create(:agent_run, :completed, project: agent_run.project) }
    let!(:fly_run) { create(:agent_run, :completed, project: agent_run.project) }

    let!(:local_usage) do
      create(:execution_usage,
        agent_run: local_run,
        runner_backend: "local",
        provisioned_at: 2.hours.ago,
        terminated_at: 1.hour.ago,
        termination_reason: "completed")
    end

    let!(:fly_usage) do
      create(:execution_usage,
        agent_run: fly_run,
        runner_backend: "fly_machine",
        provisioned_at: 2.hours.ago,
        terminated_at: 1.hour.ago,
        termination_reason: "completed")
    end

    it "filters by runner_backend" do
      expect(described_class.by_runner_backend("local")).to contain_exactly(local_usage)
      expect(described_class.by_runner_backend("fly_machine")).to contain_exactly(fly_usage)
    end

    it "filters by termination window" do
      expect(described_class.terminated_in(2.hours.ago, Time.current)).to contain_exactly(local_usage, fly_usage)
    end

    it "excludes zero-cost rows when filtered to with_cost" do
      zero = create(:agent_run, :completed, project: agent_run.project)
      zero_usage = create(:execution_usage,
        agent_run: zero,
        runner_backend: "local",
        provisioned_at: 2.hours.ago,
        terminated_at: 1.hour.ago,
        infra_cost_cents: 0)
      nonzero = create(:agent_run, :completed, project: agent_run.project)
      nonzero_usage = create(:execution_usage,
        agent_run: nonzero,
        runner_backend: "local",
        provisioned_at: 2.hours.ago,
        terminated_at: 1.hour.ago,
        infra_cost_cents: 25)

      expect(described_class.with_cost).to contain_exactly(nonzero_usage)
      expect(described_class.with_cost).not_to include(zero_usage)
    end
  end

  describe "#completed_termination?" do
    it "is true only when termination_reason is completed" do
      usage = build(:execution_usage, agent_run: agent_run, termination_reason: "completed")
      expect(usage.completed_termination?).to be(true)

      usage.termination_reason = "failed"
      expect(usage.completed_termination?).to be(false)
    end
  end

  describe "multiple cycles per agent run" do
    it "allows multiple ExecutionUsage rows for the same AgentRun" do
      first = create(:execution_usage, agent_run: agent_run)
      second = build(:execution_usage,
        agent_run: agent_run,
        provisioned_at: 20.minutes.ago,
        execution_started_at: 20.minutes.ago,
        completed_at: 10.minutes.ago,
        terminated_at: 10.minutes.ago)

      expect { second.save! }.to change(described_class, :count).by(1)
      expect(agent_run.reload.execution_usages.order(:id)).to contain_exactly(first, second)
    end
  end
end
