# frozen_string_literal: true

require "rails_helper"
require "rake"

# @spec TRUSTED-MEASUREMENTS-003
RSpec.describe Rake::Task do
  let(:task) { described_class["trusted_measurements:run_check"] }
  let(:project) { create(:project) }
  let!(:issue) { create(:issue, project:, github_number: 4812) }

  around do |example|
    keys = %w[PROJECT_ID TARGET_REVISION CHECK_KEY EXTERNAL_ISSUE_NUMBER CRITERION_KEY]
    previous = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    ENV["PROJECT_ID"] = project.id.to_s
    ENV["TARGET_REVISION"] = "reviewed-revision"
    example.run
  ensure
    keys.each { |key| ENV.delete(key) }
    previous.each { |key, value| ENV[key] = value }
  end

  before do
    Rails.application.load_tasks unless described_class.task_defined?("trusted_measurements:run_check")
    task.reenable
    allow(TrustedMeasurements::DeploymentSignal).to receive(:current).and_return("reviewed-revision")
  end

  it "collects a tenant-scoped result from a process without tenant context" do
    TenantContext.with(nil) do
      expect { task.invoke }.to output(/status:\s+succeeded/).to_stdout
      expect(Current.account).to be_nil
      expect(TenantContext.bypass_enabled?).to be(false)
    end

    attempt = TrustedMeasurementAttempt.find_by!(issue:)
    expect(attempt).to have_attributes(account_id: project.account_id, project_id: project.id, status: "succeeded")
    expect(attempt.result).to include("active_closed_issue_count" => 0, "project_scope" => "project:#{project.id}:#{project.full_name}")
  end
end
