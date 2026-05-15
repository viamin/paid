# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunMarketplaceEntry, :no_db do
  it "rejects marketplace entries from a different account than the run" do
    attachment = build_attachment(
      run_account_id: 1,
      entry_account_id: 2
    )

    attachment.send(:entry_belongs_to_agent_run_account)

    expect(attachment.errors[:marketplace_entry]).to include("must belong to the same account as the agent run")
  end

  it "accepts marketplace entries from the run account" do
    attachment = build_attachment(
      run_account_id: 1,
      entry_account_id: 1
    )

    attachment.send(:entry_belongs_to_agent_run_account)

    expect(attachment.errors[:marketplace_entry]).to be_empty
  end

  def build_attachment(run_account_id:, entry_account_id:)
    attachment = described_class.allocate
    errors = ActiveModel::Errors.new(attachment)
    run = Struct.new(:project).new(Struct.new(:account_id).new(run_account_id))
    entry = Struct.new(:account_id).new(entry_account_id)

    allow(attachment).to receive_messages(
      agent_run: run,
      marketplace_entry: entry,
      errors: errors
    )

    attachment
  end
end
