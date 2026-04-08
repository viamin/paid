# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notifications" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before { sign_in user }

  describe "GET /notifications" do
    it "renders the notifications index" do
      create(:notification, account: account, title: "Test alert")

      get notifications_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Test alert")
    end

    it "filters by unread" do
      unread = create(:notification, account: account, title: "Unread alert")
      create(:notification, :read, account: account, title: "Read alert")

      get notifications_path(filter: "unread")
      expect(response.body).to include(unread.title)
      expect(response.body).not_to include("Read alert")
    end

    it "filters by severity" do
      create(:notification, :warning, account: account, title: "Warning alert")
      create(:notification, :error, account: account, title: "Error alert")

      get notifications_path(severity: "error")
      doc = Nokogiri::HTML(response.body)
      table_text = doc.at_css("table")&.text
      expect(table_text).to include("Error alert")
      expect(table_text).not_to include("Warning alert")
    end

    it "excludes dismissed notifications" do
      create(:notification, account: account, title: "Active alert")
      create(:notification, :dismissed, account: account, title: "Dismissed alert")

      get notifications_path
      expect(response.body).to include("Active alert")
      expect(response.body).not_to include("Dismissed alert")
    end

    context "when not authenticated" do
      before { sign_out user }

      it "redirects to sign in" do
        get notifications_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "PATCH /notifications/:id/read" do
    it "marks the notification as read" do
      notification = create(:notification, account: account)

      patch read_notification_path(notification)
      expect(notification.reload.read_at).to be_present
    end

    it "redirects back for HTML requests" do
      notification = create(:notification, account: account)

      patch read_notification_path(notification)
      expect(response).to redirect_to(notifications_path)
    end
  end

  describe "PATCH /notifications/:id/dismiss" do
    it "marks the notification as dismissed" do
      notification = create(:notification, account: account)

      patch dismiss_notification_path(notification)
      expect(notification.reload.dismissed_at).to be_present
    end
  end

  describe "POST /notifications/mark_all_read" do
    it "marks all unread notifications as read" do
      n1 = create(:notification, account: account)
      n2 = create(:notification, account: account)
      already_read = create(:notification, :read, account: account)

      post mark_all_read_notifications_path
      expect(n1.reload.read_at).to be_present
      expect(n2.reload.read_at).to be_present
      expect(already_read.reload.read_at).to be_present
    end
  end

  describe "multi-tenant scoping" do
    it "does not show notifications from other accounts" do
      other_account = create(:account)
      create(:notification, account: other_account, title: "Other account alert")
      create(:notification, account: account, title: "My alert")

      get notifications_path
      expect(response.body).to include("My alert")
      expect(response.body).not_to include("Other account alert")
    end
  end
end
