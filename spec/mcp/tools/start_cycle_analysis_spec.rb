# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::StartCycleAnalysis do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }

  # @spec AUTO-PICK-QUEUE-016
  it "advertises and requires confirmation for the bounded GitHub repair" do
    expect(described_class.description).to include("may remove one verified GitHub dependency declaration")
    expect(described_class.input_schema.fetch(:required)).to include("confirmed")

    expect {
      tool.call(project_id: project.id, occurrence: "state:dependency_cycle:test", confirmed: false)
    }.to raise_error(ArgumentError, /authorize a bounded cycle repair attempt/)
  end
end
