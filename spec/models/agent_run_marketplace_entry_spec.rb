# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunMarketplaceEntry do
  it "requires the version to belong to the selected marketplace entry" do
    run = create(:agent_run)
    entry = create(:marketplace_entry, account: run.account)
    other_entry = create(:marketplace_entry, account: run.account)
    other_version = create(:marketplace_entry_version, marketplace_entry: other_entry)

    attachment = described_class.new(
      agent_run: run,
      marketplace_entry: entry,
      marketplace_entry_version: other_version,
      attachment_source: "manual",
      rendered_format: "canonical_v1",
      rendered_payload: {},
      position: 0
    )

    expect(attachment).not_to be_valid
    expect(attachment.errors[:marketplace_entry_version]).to include("must belong to the associated marketplace entry")
  end
end
