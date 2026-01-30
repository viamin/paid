# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunLog do
  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
  end

  describe "validations" do
    subject { build(:agent_run_log) }

    it { is_expected.to validate_presence_of(:log_type) }
    it { is_expected.to validate_inclusion_of(:log_type).in_array(described_class::LOG_TYPES) }
    it { is_expected.to validate_presence_of(:content) }
  end

  describe "scopes" do
    describe ".by_type" do
      it "returns logs with the specified type" do
        stdout_log = create(:agent_run_log, :stdout)
        create(:agent_run_log, :stderr)

        expect(described_class.by_type("stdout")).to include(stdout_log)
        expect(described_class.by_type("stdout").count).to eq(1)
      end
    end

    describe ".stdout" do
      it "returns only stdout logs" do
        stdout_log = create(:agent_run_log, :stdout)
        create(:agent_run_log, :stderr)

        expect(described_class.stdout).to include(stdout_log)
        expect(described_class.stdout.count).to eq(1)
      end
    end

    describe ".stderr" do
      it "returns only stderr logs" do
        stderr_log = create(:agent_run_log, :stderr)
        create(:agent_run_log, :stdout)

        expect(described_class.stderr).to include(stderr_log)
        expect(described_class.stderr.count).to eq(1)
      end
    end

    describe ".system" do
      it "returns only system logs" do
        system_log = create(:agent_run_log, :system)
        create(:agent_run_log, :stdout)

        expect(described_class.system).to include(system_log)
        expect(described_class.system.count).to eq(1)
      end
    end

    describe ".metric" do
      it "returns only metric logs" do
        metric_log = create(:agent_run_log, :metric)
        create(:agent_run_log, :stdout)

        expect(described_class.metric).to include(metric_log)
        expect(described_class.metric.count).to eq(1)
      end
    end

    describe ".recent" do
      it "orders by created_at descending" do
        older_log = create(:agent_run_log, created_at: 1.hour.ago)
        newer_log = create(:agent_run_log, created_at: 1.minute.ago)

        expect(described_class.recent.first).to eq(newer_log)
        expect(described_class.recent.last).to eq(older_log)
      end
    end

    describe ".chronological" do
      it "orders by created_at ascending" do
        older_log = create(:agent_run_log, created_at: 1.hour.ago)
        newer_log = create(:agent_run_log, created_at: 1.minute.ago)

        expect(described_class.chronological.first).to eq(older_log)
        expect(described_class.chronological.last).to eq(newer_log)
      end
    end
  end

  describe "constants" do
    it "defines valid LOG_TYPES" do
      expect(described_class::LOG_TYPES).to eq(%w[stdout stderr system metric])
    end
  end

  describe "metadata JSONB storage" do
    it "stores metadata as JSONB" do
      metadata = { tokens_input: 1000, tokens_output: 500 }
      log = create(:agent_run_log, metadata: metadata)
      reloaded = described_class.find(log.id)

      expect(reloaded.metadata).to eq(metadata.stringify_keys)
    end

    it "allows nil metadata" do
      log = create(:agent_run_log, metadata: nil)
      expect(log.metadata).to be_nil
    end
  end

  describe "agent_run association" do
    it "is destroyed when agent_run is destroyed" do
      agent_run = create(:agent_run)
      log = create(:agent_run_log, agent_run: agent_run)

      expect { agent_run.destroy }.to change(described_class, :count).by(-1)
      expect { log.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
