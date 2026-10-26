# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  # @spec LAYERED-VERIFY-014
  it "dispatches the confirmed request through the shared audit request service" do
    result = described_class.new(user:, session: nil).dispatch(project_id: project.id, confirmed: true)

    expect(result).to include("goal" => "layered_verification_audit", "project_id" => project.id)
  end

  # @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
  it "does not advertise an audit for a project whose rollout gate is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    expect(described_class.available_to?(user:)).to be(false)
  end
end
