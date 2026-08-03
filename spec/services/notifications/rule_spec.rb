# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rule do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:rule_class) do
    Class.new(described_class) do
      def source = "test_rule"

      def detect(scope)
        Array(scope).select(&:auto_pick_enabled?)
      end

      def build(_subject)
        {
          severity: :warning,
          title: "Matched",
          nav_section: "projects",
          action_url: "/projects"
        }
      end
    end
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  it "publishes matching notifications and resolves cleared ones" do
    matching = create(:project, account: account, auto_pick_enabled: true)
    cleared = create(:project, account: account, auto_pick_enabled: false)
    create(:notification, account: account, source: "test_rule", subject: cleared)

    expect {
      rule_class.call(scope: [ matching, cleared ])
    }.to change(Notification, :count).by(1)

    expect(Notification.find_by!(account: account, source: "test_rule", subject: matching)).to be_present
    expect(Notification.find_by!(account: account, source: "test_rule", subject: cleared).resolved_at).to be_present
  end

  it "clears persisted rule state when a notification resolves" do
    project.update!(auto_pick_enabled: false)
    create(:notification, account: account, source: "test_rule", subject: project)
    create(:notification_rule_state, account: account, source: "test_rule", subject: project)

    expect {
      rule_class.call(scope: [ project ])
    }.to change(NotificationRuleState, :count).by(-1)
  end

  it "forwards evaluation context to each registered rule" do
    rule = class_double(rule_class, call: nil)
    described_class.register(rule)

    described_class.evaluate_all(account: account, test_context: { project_id: project.id })

    expect(rule).to have_received(:call).with(scope: account, test_context: { project_id: project.id })
  ensure
    described_class.rule_classes.clear
  end
end
