# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationPolicy do
  describe "Scope" do
    it "includes account-wide notifications (user_id nil)" do
      account = create(:account)
      user = create(:user, account: account)
      notification = create(:notification, account: account, user: nil, source: "test", subject: account)

      scope = described_class::Scope.new(user, Notification.all).resolve
      expect(scope).to include(notification)
    end

    it "includes the current user's personal notifications" do
      account = create(:account)
      user = create(:user, account: account)
      notification = create(:notification, account: account, user: user, source: "test", subject: account)

      scope = described_class::Scope.new(user, Notification.all).resolve
      expect(scope).to include(notification)
    end

    it "excludes another user's personal notifications" do
      account = create(:account)
      user = create(:user, account: account)
      other_user = create(:user, account: account)
      other_notification = create(:notification, account: account, user: other_user, source: "test", subject: account)

      scope = described_class::Scope.new(user, Notification.all).resolve
      expect(scope).not_to include(other_notification)
    end

    it "excludes notifications from other accounts" do
      account = create(:account)
      user = create(:user, account: account)
      other_account = create(:account)
      other_notification = create(:notification, account: other_account, user: nil, source: "test",
        subject: other_account)

      scope = described_class::Scope.new(user, Notification.all).resolve
      expect(scope).not_to include(other_notification)
    end
  end
end
