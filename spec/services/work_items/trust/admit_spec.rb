# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Trust::Admit do
  let(:project) { create(:project) }
  let(:account) { project.account }

  before { FeatureFlags.enable!(:unified_work_items, project:) }

  it "trusts an account-wide default identity" do
    # @spec UNIFIED-WORK-ITEMS-004
    create(:trusted_provider_identity, account:, identity_type: "user", external_id: "linear-user-1")

    expect(described_class.trusted?(project:, provider: "linear", identity_type: "user", external_id: "linear-user-1")).to be true
  end

  it "trusts a project-level addition not present in the account default" do
    create(:trusted_provider_identity, account:, project:, identity_type: "team", external_id: "team-eng")

    expect(described_class.trusted?(project:, provider: "linear", identity_type: "team", external_id: "team-eng")).to be true
  end

  it "trusts a user explicitly mapped from the provider identity" do
    # @spec UNIFIED-WORK-ITEMS-005
    user = create(:user, account:)
    create(:provider_identity_mapping, account:, user:, provider: "linear", external_id: "linear-user-1")

    expect(described_class.trusted?(project:, provider: "linear", identity_type: "user", external_id: "linear-user-1")).to be true
  end

  it "does not treat a user mapping as a trusted provider team" do
    create(:provider_identity_mapping, account:, provider: "linear", external_id: "linear-user-1")

    expect(described_class.trusted?(project:, provider: "linear", identity_type: "team", external_id: "linear-user-1")).to be false
  end

  it "does not trust an unlisted identity" do
    expect(described_class.trusted?(project:, provider: "linear", identity_type: "user", external_id: "unknown")).to be false
  end

  it "never trusts anything while the rollout guard is disabled" do
    # @spec UNIFIED-WORK-ITEMS-009
    other_project = create(:project)
    create(:trusted_provider_identity, account: other_project.account, identity_type: "user", external_id: "linear-user-1")

    expect(described_class.trusted?(project: other_project, provider: "linear", identity_type: "user", external_id: "linear-user-1")).to be false
  end
end
