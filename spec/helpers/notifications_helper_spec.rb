# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationsHelper, :db do
  describe "#unread_notification_count" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before do
      current_account, current_user = account, user
      helper.define_singleton_method(:current_account) { current_account }
      helper.define_singleton_method(:current_user) { current_user }
    end

    it "returns 0 when there is no current account" do
      allow(helper).to receive(:current_account).and_return(nil)

      expect(helper.unread_notification_count).to eq(0)
    end

    # @spec NOTIFICATION-SEVERITY-004
    it "counts unread warning and error notifications" do
      create(:notification, :warning, account: account)
      create(:notification, :error, account: account)

      expect(helper.unread_notification_count).to eq(2)
    end

    # @spec NOTIFICATION-SEVERITY-004
    it "excludes unread info notifications from the count" do
      create(:notification, :info, account: account)
      create(:notification, :warning, account: account)

      expect(helper.unread_notification_count).to eq(1)
    end

    it "excludes read notifications" do
      create(:notification, :warning, :read, account: account)

      expect(helper.unread_notification_count).to eq(0)
    end

    it "excludes dismissed and resolved notifications" do
      create(:notification, :warning, :dismissed, account: account)
      create(:notification, :error, :resolved, account: account)

      expect(helper.unread_notification_count).to eq(0)
    end
  end
end
