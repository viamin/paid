# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::EffectivePrivacyPolicy do
  # @spec MODEL-POLICY-022
  it "unions project, runner, and preserved requirements without allowing an override to weaken them" do
    project = create(:project, data_classification: "restricted")
    runner = create(:runner, user: project.created_by, zero_data_retention: false)

    policy = described_class.call(project: project, runner: runner, required_zdr: false)

    expect(policy).to have_attributes(project_requires_zdr: true, zdr_required: true, provenance: "unavailable", eligible: false)
  end
end
