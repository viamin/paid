# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-014
  it "requires confirmation and dispatches the shared audit request" do
    expect(described_class.write_operation?).to be(true)
    expect(described_class.confirmation_mode).to eq(:post_dispatch)
    expect(described_class.mcp_available?).to be(true)
  end
end
