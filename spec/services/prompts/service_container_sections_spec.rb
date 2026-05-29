# frozen_string_literal: true

require "rails_helper"

RSpec.describe Prompts::ServiceContainerSections do
  describe ".render_available_services_intro_result" do
    let(:project) { create(:project) }

    it "keeps the attempted slug in fallback provenance" do
      Prompt.find_by(slug: described_class::AVAILABLE_SERVICES_INTRO_SLUG)&.destroy!

      result = described_class.render_available_services_intro_result(project: project)

      expect(result.prompt_provenance).to include(
        slug: described_class::AVAILABLE_SERVICES_INTRO_SLUG,
        prompt_id: nil,
        prompt_version_id: nil,
        version_number: nil,
        source: "fallback"
      )
    end
  end
end
