# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CaptureScreenshotsActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }

  describe "#execute" do
    it "delegates screenshot capture to the container capture service" do
      result = Screenshots::ContainerCapture::Result.new(
        status: "captured",
        changed_files: [ "app/views/projects/show.html.erb" ],
        ui_files: [ "app/views/projects/show.html.erb" ],
        screenshot_paths: [ "/tmp/screenshots/home.png" ],
        published: false,
        screenshots_url: nil,
        error: nil
      )

      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(Screenshots::ContainerCapture).to receive(:call).with(agent_run: agent_run, logger: Rails.logger).and_return(result)

      activity_result = activity.execute(agent_run_id: agent_run.id)

      expect(activity_result).to include(
        agent_run_id: agent_run.id,
        status: "captured",
        screenshot_count: 1,
        screenshots_url: nil,
        error: nil
      )
    end
  end
end
