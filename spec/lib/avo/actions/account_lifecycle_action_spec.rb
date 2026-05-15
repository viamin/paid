# frozen_string_literal: true

require "rails_helper"

RSpec.describe Avo::Actions::AccountLifecycleAction, :no_db do
  let(:account_class) do
    Struct.new(:id, :name) do
      def suspend!; end

      def reactivate!; end

      def deactivate!; end
    end
  end
  let(:account) { account_class.new(11, "Acme") }
  let(:current_user) { Struct.new(:id, :email).new(7, "operator@example.com") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: true) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe Avo::Actions::SuspendAccount do
    it "suspends the account and records a success message" do
      allow(account).to receive(:suspend!)

      action = described_class.new.handle(query: [ account ], fields: {}, current_user:, resource: nil)

      expect(account).to have_received(:suspend!)
      expect(logger).to have_received(:info).with(
        hash_including(
          message: "operator_console.account_lifecycle",
          action: "suspend",
          actor_user_id: 7,
          actor_user_email: "operator@example.com",
          account_id: 11,
          outcome: "success"
        )
      )
      expect(action.response[:messages]).to include(
        hash_including(type: :success, body: "Suspended account Acme.")
      )
    end
  end

  describe Avo::Actions::ReactivateAccount do
    it "reactivates the account and records a success message" do
      allow(account).to receive(:reactivate!)

      action = described_class.new.handle(query: [ account ], fields: {}, current_user:, resource: nil)

      expect(account).to have_received(:reactivate!)
      expect(action.response[:messages]).to include(
        hash_including(type: :success, body: "Reactivated account Acme.")
      )
    end
  end

  describe Avo::Actions::DeactivateAccount do
    it "deactivates the account and records a success message" do
      allow(account).to receive(:deactivate!)

      action = described_class.new.handle(query: [ account ], fields: {}, current_user:, resource: nil)

      expect(account).to have_received(:deactivate!)
      expect(action.response[:messages]).to include(
        hash_including(type: :success, body: "Deactivated account Acme.")
      )
    end
  end

  it "rejects bulk actions so operators cannot bypass single-account review" do
    action = Avo::Actions::SuspendAccount.new.handle(query: [ account, account ], fields: {}, current_user:, resource: nil)

    expect(action.response[:messages]).to include(
      hash_including(type: :error, body: "Select exactly one account.")
    )
  end

  it "reports invalid lifecycle transitions from the account model" do
    allow(account).to receive(:suspend!).and_raise(Account::InvalidTransitionError, "only active accounts can be suspended")

    action = Avo::Actions::SuspendAccount.new.handle(query: [ account ], fields: {}, current_user:, resource: nil)

    expect(action.response[:messages]).to include(
      hash_including(type: :error, body: "only active accounts can be suspended")
    )
  end
end
