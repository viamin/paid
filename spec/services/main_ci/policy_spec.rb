# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCi::Policy, :no_db do
  let(:project) { Project.new(review_settings: {}) }

  # @spec MAIN-CI-007
  it "is disabled without explicit owner policy" do
    expect(described_class.new(project)).not_to be_enabled
  end

  # @spec MAIN-CI-003
  it "requires explicit workflows and a known-good executor revision" do
    project.review_settings = { "main_ci_recovery" => { "enabled" => true } }
    expect(described_class.new(project)).not_to be_valid
  end
end
