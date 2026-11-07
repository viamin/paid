# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseoutStallProjectionJob do # @spec PARTIAL-CLOSEOUT-042
  describe "GoodJob concurrency" do
    it "bounds queued and performing recomputations per project" do
      config = described_class.good_job_concurrency_config

      expect(described_class.queue_name).to eq("maintenance")
      expect(config).to include(enqueue_limit: 2, perform_limit: 1)
      expect(config[:key]).to respond_to(:call)
      job = described_class.new(41)
      expect(config[:key].call(job)).to eq("partial_closeout_stall_projection:41")
    end
  end

  describe "#perform" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) do
      create(:project, account: account, created_by: user, active: true, auto_pick_enabled: true,
        owner: "acme", repo: "alpha")
    end

    before do
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
    end

    it "recomputes the projection for an enrolled project" do
      FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
      allow(Issues::StalledCloseoutProjection).to receive(:recompute!).and_call_original

      described_class.perform_now(project.id)

      expect(Issues::StalledCloseoutProjection).to have_received(:recompute!).with(project)
      expect(PartialCloseoutStallCheckpoint.find_by(project: project)).to be_evaluated
    end

    it "skips projects that are not enrolled" do
      allow(Issues::StalledCloseoutProjection).to receive(:recompute!)

      described_class.perform_now(project.id)

      expect(Issues::StalledCloseoutProjection).not_to have_received(:recompute!)
    end

    it "records a failed recomputation without raising" do
      FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
      result = Issues::StalledCloseoutProjection::Result.new(success: false, generation: nil,
        stalled_count: nil, error: RuntimeError.new("boom"))
      allow(Issues::StalledCloseoutProjection).to receive(:recompute!).and_return(result)

      expect { described_class.perform_now(project.id) }.not_to raise_error
    end
  end
end
