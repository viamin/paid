# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-010
  # @spec LAYERED-VERIFY-013
  # @spec LAYERED-VERIFY-014
  it "returns scope, sources, revision, and budget before dispatch" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "source-sha")
    user = create(:user, account: project.account)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    policy = instance_double(ProjectPolicy, manage_issues?: true)
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(policy)

    result = described_class.new(user:, session: nil).dispatch(project_id: project.id, obligation_ids: [ obligation.id ], budget_tokens: 500)

    expect(result).to include("source_references" => [ obligation.external_identity ], "target_revision" => [ "source-sha" ], "budget_tokens" => 500, "dispatch" => "awaiting_confirmation")
  end
end
