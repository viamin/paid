# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::CodeScanningPermissionsError do
  let(:project) { create(:project, security_alert_types: %w[code_scanning]) }

  before { allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) }

  it "publishes a blocking notification during the permission-error backoff" do # @spec EAGER-QUEUE-016
    project.update!(code_scanning_permission_error_at: 5.minutes.ago)

    expect {
      described_class.call(scope: [ project ])
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "code_scanning_permissions_error", subject: project)
    expect(notification).to have_attributes(severity: "error", blocking: true)
  end

  it "does not publish after the permission-error backoff has elapsed" do # @spec EAGER-QUEUE-016
    project.update!(code_scanning_permission_error_at: 2.hours.ago)

    expect {
      described_class.call(scope: [ project ])
    }.not_to change(Notification, :count)
  end

  it "auto-resolves after a successful scan clears the error" do # @spec EAGER-QUEUE-016
    project.update!(code_scanning_permission_error_at: 5.minutes.ago)
    described_class.call(scope: [ project ])
    project.update!(code_scanning_permission_error_at: nil)

    expect {
      described_class.call(scope: [ project ])
    }.to change { Notification.active.where(source: "code_scanning_permissions_error", subject: project).count }.by(-1)
  end
end
