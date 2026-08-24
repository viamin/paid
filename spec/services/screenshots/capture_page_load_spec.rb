# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::Capture do
  describe "rake capture path" do
    let(:project) { create(:project, screenshot_settings: { "enabled" => true }) }

    # @spec PAGE-LOAD-MEASURE-010
    it "records no page load measurements" do
      allow(Screenshots::CaptureOrchestrator).to receive(:call).and_return(
        Screenshots::CaptureOrchestrator::RunResult.new(captures: [], failures: [])
      )

      expect { described_class.call(repo_path: Dir.mktmpdir, project: project) }
        .not_to change(PageLoadMeasurement, :count)
    end
  end
end
