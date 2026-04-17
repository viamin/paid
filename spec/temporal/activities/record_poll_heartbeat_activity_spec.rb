# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordPollHeartbeatActivity do
  let(:activity) { described_class.new }

  describe "#execute" do
    let(:project) { create(:project) }

    it "updates last_polled_at on the project" do
      freeze_time do
        activity.execute(project_id: project.id)

        expect(project.reload.last_polled_at).to eq(Time.current)
      end
    end

    it "returns recorded: true for existing projects" do
      result = activity.execute(project_id: project.id)

      expect(result[:recorded]).to be true
    end

    it "returns recorded: false when project is missing" do
      result = activity.execute(project_id: -1)

      expect(result[:recorded]).to be false
    end
  end
end
