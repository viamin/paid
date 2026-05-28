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

    it "renders a revert button for applied remediation notifications" do
      create(
        :notification,
        account: account,
        title: "Self-heal alert",
        metadata: { revert_url: "/remediation_decisions/123/revert" }
      )

      get notifications_path

      expect(response.body).to include("Revert")
      expect(response.body).to include("/remediation_decisions/123/revert")
    end

    it "renders the table with mobile horizontal scrolling constraints" do
      create(:notification, account: account, title: "Scrollable alert")

      get notifications_path

      doc = Nokogiri::HTML(response.body)
      scroll_wrapper = doc.at_css("div.overflow-x-auto > table.min-w-full")
      header_classes = doc.css("table thead th").map { |header| header["class"] }

      expect(scroll_wrapper).to be_present
      expect(header_classes).to include(a_string_including("min-w-[5rem]"))
      expect(header_classes).to include(a_string_including("min-w-[16rem]"))
      expect(header_classes).to include(a_string_including("min-w-[6rem]"))
      expect(header_classes).to include(a_string_including("min-w-[7rem]"))
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

    it "ignores invalid severity params" do
      create(:notification, :warning, account: account, title: "Warning alert")

      get notifications_path(severity: "bogus")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Warning alert")
    end

    it "renders dropdown content when dropdown param is true" do
      create(:notification, account: account, title: "Dropdown alert")

      get notifications_path(dropdown: "true")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dropdown alert")
    end

    it "targets action links at the top frame in dropdown content" do
      notification = create(:notification, :with_action_url, account: account, title: "Linked alert")

      get notifications_path(dropdown: "true")

      link = Nokogiri::HTML(response.body)
        .css("a")
        .find { |anchor| anchor.text == notification.title }

      expect(link["href"]).to eq(notification.action_url)
      expect(link["data-turbo-frame"]).to eq("_top")
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

    it "preserves the current query params in the mark all read form" do
      get notifications_path(filter: "unread", severity: "error", source: "quality_gate")

      doc = Nokogiri::HTML(response.body)
      form = doc.at_css("form.button_to[action='#{mark_all_read_notifications_path}']")

      expect(form.at_css("input[name='filter']")["value"]).to eq("unread")
      expect(form.at_css("input[name='severity']")["value"]).to eq("error")
      expect(form.at_css("input[name='source']")["value"]).to eq("quality_gate")
    end

    it "redirects back to the filtered index for HTML requests" do
      post mark_all_read_notifications_path, params: { filter: "unread", severity: "error", source: "quality_gate" }

      expect(response).to redirect_to(notifications_path(filter: "unread", severity: "error", source: "quality_gate"))
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
