# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListRunners do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  # @spec RUNNER-ZDR-007
  it "serializes the declaration and derived provenance within the authorized scope" do
    runner = create(:runner, user:, runner_key: "cursor", zdr_required: true)

    result = described_class.new(user:, session:).call

    serialized = result.fetch(:runners).find { |item| item.fetch("id") == runner.id }
    expect(serialized).to include("zdr_required" => true, "zdr_provenance" => "user_declared")
  end
end
