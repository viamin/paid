# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureFlags do
  it "defines operational_supervisor as a default-off project rollout guard" do # @spec OPERATIONAL-SUPERVISOR-008
    project = create(:project)

    expect(described_class::DEFINITIONS).to include(:operational_supervisor)
    expect(described_class.enabled?(:operational_supervisor, project:)).to be(false)
    expect(described_class.definition(:operational_supervisor).rollout_plan).to include("Default-off")
  end
end
