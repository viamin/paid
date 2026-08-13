# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorTools::Registry do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:chat_session) { build(:chat_session, account:, created_by: user) }

  around do |example|
    original_emails = ENV["PAID_OPERATOR_EMAILS"]
    ENV["PAID_OPERATOR_EMAILS"] = user.email
    example.run
  ensure
    ENV["PAID_OPERATOR_EMAILS"] = original_emails
  end

  it "does not make operator tools available to non-operators" do
    non_operator = create(:user, :owner, account: create(:account))

    available = described_class.send(
      :tool_available_to?,
      OperatorTools::ListAccounts,
      user: non_operator
    )

    expect(available).to be(false)
  end

  it "advertises operator tools to operators in chat" do
    names = described_class.chat_definitions_for(user:, session: chat_session).map { |definition| definition[:name] }

    expect(names).to include(
      "operator_console_inventory",
      "operator_list_accounts",
      "operator_suspend_account",
      "operator_recompress_style_guides"
    )
  end

  it "strips the confirmation flag from operator write tools in chat" do
    schema = described_class.chat_definitions_for(user:, session: chat_session)
      .find { |definition| definition[:name] == "operator_suspend_account" }
      .fetch(:inputSchema)

    expect(schema[:properties]).not_to have_key(:confirmed)
    expect(schema[:required]).not_to include("confirmed")
  end
end
