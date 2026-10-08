# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::CodeScanningAvailability do
  let(:project) do
    create(:project, security_alert_types: %w[dependabot code_scanning],
      last_code_scanning_scan_at: 2.days.ago)
  end
  let(:client) { instance_double(GithubClient) }

  before { allow(project).to receive(:client).and_return(client) }

  # @spec GITHUB-SYNC-020
  it "classifies GitHub's Advanced Security prerequisite response as unavailable" do
    error = GithubClient::ApiError.new(
      "Advanced Security must be enabled for this repository to use code scanning.", status: 403
    )

    expect(described_class.unavailable_response?(error)).to be(true)
  end

  # @spec GITHUB-SYNC-020
  it "removes only code scanning and resolves the permission notification for an Advanced Security prerequisite" do
    watermark = project.last_code_scanning_scan_at
    project.update!(code_scanning_permission_error_at: 5.minutes.ago)
    Notifications::Rules::CodeScanningPermissionsError.call(scope: [ project ])
    allow(client).to receive(:code_scanning_available?).and_raise(
      GithubClient::ApiError.new(
        "Advanced Security must be enabled for this repository to use code scanning.", status: 403
      )
    )

    result = described_class.call(project:, enable: false)

    expect(result).to be_unavailable
    expect(project.reload).to have_attributes(
      security_alert_types: [ "dependabot" ],
      code_scanning_scan_error_kind: "unavailable",
      code_scanning_scan_error_reason: "Advanced Security must be enabled for this repository to use code scanning.",
      code_scanning_permission_error_at: nil,
      next_code_scanning_scan_at: nil,
      last_code_scanning_scan_at: watermark
    )
    expect(Notification.active.find_by(source: "code_scanning_permissions_error", subject: project)).to be_nil
  end

  # @spec GITHUB-SYNC-020
  it "keeps code scanning selected for an ambiguous permission denial" do
    allow(client).to receive(:code_scanning_available?)
      .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

    expect { described_class.call(project:, enable: false) }.to raise_error(GithubClient::ApiError)
    expect(project.reload.security_alert_types).to contain_exactly("dependabot", "code_scanning")
  end

  # @spec GITHUB-SYNC-020
  it "keeps code scanning selected for a rate limit" do
    allow(client).to receive(:code_scanning_available?).and_raise(GithubClient::RateLimitError.new)

    expect { described_class.call(project:, enable: false) }.to raise_error(GithubClient::RateLimitError)
    expect(project.reload.security_alert_types).to contain_exactly("dependabot", "code_scanning")
  end

  # @spec GITHUB-SYNC-020
  it "enables code scanning after a successful zero-alert refresh" do
    project.update!(security_alert_types: [ "dependabot" ], code_scanning_scan_error_kind: "unavailable")
    allow(client).to receive(:code_scanning_available?).and_return(true)

    result = described_class.call(project:, enable: true)

    expect(result).to be_available
    expect(project.reload).to have_attributes(
      security_alert_types: %w[dependabot code_scanning],
      code_scanning_scan_error_kind: nil
    )
  end
end
