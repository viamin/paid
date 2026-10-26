# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  it "shows the resolved scope, sources, revision and budget before dispatch" do
    project = create(:project)
    user = create(:user, account: project.account)
    request = described_class.new(project:, user:, scope: [ "PAYMENTS-001" ], sources: [ "docs/intent/payments.md" ], target_revision: "abc123", budget: 2000, trigger: "mcp")

    expect(request.preview.to_h).to include(scope: [ "PAYMENTS-001" ], sources: [ "docs/intent/payments.md" ], target_revision: "abc123", budget: 2000)
  end
end
