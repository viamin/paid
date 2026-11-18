# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe ProjectDelegation::IntentSettlement do
  it "is append-only" do
    settlement = create(:project_delegation_intent_settlement)

    expect { settlement.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
