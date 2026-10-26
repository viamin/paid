# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do # @spec LAYERED-VERIFY-014
  it "is registered as a confirmed write operation" do
    expect(described_class.write_operation?).to be(true)
    expect(described_class.input_schema.fetch(:required)).to include("confirmed")
    expect(Tools::Registry::TOOL_CLASSES).to include("Tools::RequestLayeredVerificationAudit")
  end
end
