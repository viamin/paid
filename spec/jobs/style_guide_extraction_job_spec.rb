# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuideExtractionJob do
  let(:project) { create(:project) }

  describe "#perform" do
    it "calls StyleGuides::Extract with the project" do
      allow(StyleGuides::Extract).to receive(:call)

      described_class.new.perform(project.id)

      expect(StyleGuides::Extract).to have_received(:call).with(project: project)
    end

    it "discards when project is not found" do
      expect {
        described_class.perform_now(-1)
      }.not_to raise_error
    end

    it "logs and swallows ExtractionError" do
      allow(StyleGuides::Extract).to receive(:call).and_raise(
        StyleGuides::ExtractionError, "LLM extraction failed"
      )

      expect(Rails.logger).to receive(:error).with(
        hash_including(
          message: "style_guides.extraction_failed",
          error_class: "StyleGuides::ExtractionError",
          project_id: project.id
        )
      )

      described_class.new.perform(project.id)
    end

    it "logs and swallows AgentHarness::Error" do
      allow(StyleGuides::Extract).to receive(:call).and_raise(
        AgentHarness::Error, "Connection timeout"
      )

      expect(Rails.logger).to receive(:error).with(
        hash_including(
          message: "style_guides.extraction_failed",
          error_class: "AgentHarness::Error",
          project_id: project.id
        )
      )

      described_class.new.perform(project.id)
    end
  end
end
