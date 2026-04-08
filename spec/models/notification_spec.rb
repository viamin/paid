# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notification do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:user).optional }
    it { is_expected.to belong_to(:subject).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:source) }
    it { is_expected.to validate_presence_of(:title) }

    it "validates severity inclusion" do
      notification = build(:notification, severity: :info)
      expect(notification).to be_valid

      notification.severity = :warning
      expect(notification).to be_valid

      notification.severity = :error
      expect(notification).to be_valid
    end
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:severity).with_values(info: 0, warning: 1, error: 2) }
  end

  describe "scopes" do
    let(:account) { create(:account) }

    describe ".unread" do
      it "returns notifications without read_at" do
        unread = create(:notification, account: account)
        create(:notification, :read, account: account)

        expect(described_class.unread).to contain_exactly(unread)
      end
    end

    describe ".undismissed" do
      it "returns notifications without dismissed_at" do
        active = create(:notification, account: account)
        create(:notification, :dismissed, account: account)

        expect(described_class.undismissed).to contain_exactly(active)
      end
    end

    describe ".unresolved" do
      it "returns notifications without resolved_at" do
        active = create(:notification, account: account)
        create(:notification, :resolved, account: account)

        expect(described_class.unresolved).to contain_exactly(active)
      end
    end

    describe ".active" do
      it "returns undismissed and unresolved notifications" do
        active = create(:notification, account: account)
        create(:notification, :dismissed, account: account)
        create(:notification, :resolved, account: account)

        expect(described_class.active).to contain_exactly(active)
      end
    end

    describe ".for_nav_section" do
      it "returns notifications for the given nav section" do
        projects = create(:notification, account: account, nav_section: "projects")
        create(:notification, account: account, nav_section: "agent_runs")

        expect(described_class.for_nav_section("projects")).to contain_exactly(projects)
      end
    end

    describe ".recent" do
      it "returns notifications ordered by created_at desc" do
        old = create(:notification, account: account, created_at: 1.day.ago)
        recent = create(:notification, account: account, created_at: 1.minute.ago)

        expect(described_class.recent).to eq([ recent, old ])
      end
    end
  end
end
