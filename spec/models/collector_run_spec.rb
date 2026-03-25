# frozen_string_literal: true

require "rails_helper"

RSpec.describe CollectorRun do
  describe "associations" do
    it { is_expected.to belong_to(:project_version) }
    it { is_expected.to have_many(:knowledge_artifacts).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:collector_run) }

    it { is_expected.to validate_presence_of(:collector_type) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(CollectorRun::STATUSES) }
    it { is_expected.to validate_uniqueness_of(:collector_type).scoped_to(:project_version_id) }
  end

  describe "#mark_running!" do
    it "transitions to running with started_at" do
      run = create(:collector_run)
      run.mark_running!

      expect(run.status).to eq("running")
      expect(run.started_at).to be_present
    end
  end

  describe "#mark_completed!" do
    it "transitions to completed with duration and count" do
      run = create(:collector_run, :running)
      run.mark_completed!(count: 5)

      expect(run.status).to eq("completed")
      expect(run.completed_at).to be_present
      expect(run.duration_ms).to be_present
      expect(run.artifacts_count).to eq(5)
    end
  end

  describe "#mark_failed!" do
    it "transitions to failed with error message" do
      run = create(:collector_run, :running)
      run.mark_failed!(error: "timeout")

      expect(run.status).to eq("failed")
      expect(run.error_message).to eq("timeout")
      expect(run.completed_at).to be_present
    end
  end
end
