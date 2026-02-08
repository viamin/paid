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

    context "with default interval" do
      let(:project) { create(:project) }

      it "returns the default 60 seconds" do
        result = activity.execute(project_id: project.id)

        expect(result[:poll_interval_seconds]).to eq(60)
      end
    end
  end
end
