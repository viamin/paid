# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::ReviewPackages::Approve do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:obligation) { create(:layered_verification_obligation, project:) }
  let(:audit) do
    create(:agent_run, project:, goal: "layered_verification_audit", status: "completed", external_metadata: {
      "layered_verification" => { "obligation_ids" => [ obligation.id ], "target_revision" => "abc123",
        "plan" => { obligation.id.to_s => { "selected_checks" => [ "semantic_audit" ] } } }
    })
  end
  let!(:package) { LayeredVerification::ReviewPackages::Capture.call(agent_run: audit) }

  before { FeatureFlags.enable!(:layered_verification_add_on, project:) }

  # @spec LAYERED-VERIFY-023
  it "rejects an approval after contributing results changed without a successor capture" do
    create(:layered_verification_check_result, obligation:, agent_run: audit)

    expect { described_class.call(package:, user:, provenance: { surface: "spec" }) }
      .to raise_error(described_class::StalePackageError)
    expect(package.reload.approvals).to be_empty
    expect(audit.review_packages.order(:revision_number).last.id).not_to eq(package.id)
  end

  # @spec LAYERED-VERIFY-023
  it "requires refreshed review of a changed plan even if obligation revisions did not change" do
    metadata = audit.external_metadata.deep_dup
    metadata["layered_verification"]["plan"][obligation.id.to_s]["fit"] = "A revised bounded review"
    audit.update!(external_metadata: metadata)

    expect { described_class.call(package:, user:, provenance: { surface: "spec" }) }
      .to raise_error(described_class::StalePackageError)
    expect(package.reload.approvals).to be_empty
  end
end
