# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::GetPollIntervalActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    let(:project) { create(:project, poll_interval_seconds: 120) }

    it "returns the project poll interval" do
      result = activity.execute(project_id: project.id)

      expect(result[:poll_interval_seconds]).to eq(120)
    end

    it "updates last_polled_at on the project" do
      freeze_time do
        activity.execute(project_id: project.id)

        expect(project.reload.last_polled_at).to eq(Time.current)
      end
    end

    it "does not update last_polled_at when project is missing" do
      result = activity.execute(project_id: -1)

      expect(result[:project_missing]).to be true
    end

    context "with default interval" do
      let(:project) { create(:project) }

      it "returns the default 60 seconds" do
        result = activity.execute(project_id: project.id)

        expect(result[:poll_interval_seconds]).to eq(60)
      end
    end
  end
end
