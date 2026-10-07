# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::CodeScanningConfigurationError do
  let(:project) { create(:project, security_alert_types: %w[code_scanning], allowed_github_usernames: []) }

  before { allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) }

  it "publishes a blocking notification when trusted GitHub usernames are missing" do # @spec EAGER-QUEUE-016
    expect {
      described_class.call(scope: [ project ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "code_scanning_configuration_error", subject: project)
    expect(notification).to have_attributes(severity: "error", blocking: true)
  end

  it "auto-resolves after trusted GitHub usernames are configured" do # @spec EAGER-QUEUE-016
    described_class.call(scope: [ project ])
    project.update!(allowed_github_usernames: [ "paid-bot" ])

    expect {
      described_class.call(scope: [ project ])
    }.to change { Notification.active.where(source: "code_scanning_configuration_error", subject: project).count }.by(-1)
  end
end
