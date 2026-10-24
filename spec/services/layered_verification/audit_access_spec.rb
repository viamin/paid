# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::AuditAccess do
  # @spec LAYERED-VERIFY-010
  # @spec LAYERED-VERIFY-012
  it "requires the default-off flag before applying the audit permission" do
    project = create(:project)
    user = create(:user, account: project.account)

    expect { described_class.authorize!(user:, project:) }
      .to raise_error(described_class::FeatureDisabledError)
  end

  # @spec LAYERED-VERIFY-010
  it "uses ProjectPolicy manage_issues? after the feature is enabled" do
    project = create(:project)
    user = create(:user)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    expect { described_class.authorize!(user:, project:) }
      .to raise_error(described_class::UnauthorizedError)
  end
end
