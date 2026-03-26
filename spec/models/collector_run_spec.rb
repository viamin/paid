# frozen_string_literal: true

require "rails_helper"

RSpec.describe CollectorRun do
  describe "associations" do
    it { is_expected.to belong_to(:project_version) }
    it { is_expected.to have_many(:knowledge_artifacts).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:collector_type) }
    it { is_expected.to validate_length_of(:collector_type).is_at_most(100) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
  end

  describe "scopes" do
    let!(:completed_run) { create(:collector_run, :completed) }
    let!(:failed_run) { create(:collector_run, :failed) }
    let!(:pending_run) { create(:collector_run) }

    describe ".completed" do
      it "returns completed runs" do
        expect(described_class.completed).to contain_exactly(completed_run)
      end
    end

    describe ".failed" do
      it "returns failed runs" do
        expect(described_class.failed).to contain_exactly(failed_run)
      end
    end

    describe ".by_status" do
      it "returns runs with matching status" do
        expect(described_class.by_status("pending")).to contain_exactly(pending_run)
      end
    end
  end

  describe "#start!" do
    it "transitions to running and sets started_at" do
      run = create(:collector_run)
      run.start!
      expect(run.status).to eq("running")
      expect(run.started_at).to be_present
    end
  end

  describe "#complete!" do
    it "transitions to completed with duration" do
      run = create(:collector_run, :running)
      run.complete!(artifacts_count: 5)
      expect(run.status).to eq("completed")
      expect(run.completed_at).to be_present
      expect(run.artifacts_count).to eq(5)
    end
  end

  describe "#fail!" do
    it "transitions to failed with error message" do
      run = create(:collector_run, :running)
      run.fail!(error_message: "timeout")
      expect(run.status).to eq("failed")
      expect(run.error_message).to eq("timeout")
      expect(run.completed_at).to be_present
    end
  end
end
