# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "shows the resolved scope before dispatch" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    user = project.account.users.first || create(:user, account: project.account)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow_any_instance_of(ProjectPolicy).to receive(:manage_issues?).and_return(true)

    result = described_class.new(user:, session: nil).dispatch(
      project_id: project.id, obligation_ids: [ obligation.id ], target_revision: "abc123", budget: 100, confirmed: false
    )

    expect(result).to include("resolved_scope" => [ obligation.external_identity ], "dispatch_required" => true)
  end
end
