# frozen_string_literal: true

require "rails_helper"

RSpec.describe PgHeroOverviewScanJob do
  # @spec RAILS-CONTROL-PLANE-025
  it "does not invoke the scanner outside development" do
    expect(Development::PgHeroOverview::Scan).not_to receive(:new)

    expect { described_class.perform_now }.not_to raise_error
  end

  it "runs on the maintenance queue" do
    expect(described_class.queue_name).to eq("maintenance")
  end

  # @spec RAILS-CONTROL-PLANE-026
  it "prevents concurrent and overlapping scans" do
    config = described_class.good_job_concurrency_config

    expect(config[:total_limit]).to eq(1)
    expect(config[:enqueue_limit]).to eq(1)
    expect(config[:key]).to eq("pghero_overview_scan")
  end

  # @spec RAILS-CONTROL-PLANE-029
  it "retries GitHub failures a bounded number of times" do
    account = create(:account)
    allow(Rails).to receive(:env).and_return("development".inquiry)
    create(:project, account: account, owner: "viamin", repo: "paid")
    create(:tenant_setting, account: account, self_repo_full_name: "viamin/paid")
    allow(Development::PgHeroOverview::Scan).to receive(:new).and_raise(GithubClient::Error.new("lookup failed"))

    described_class.perform_now

    expect(enqueued_jobs_count_for(described_class)).to eq(1)
  end

  # @spec RAILS-CONTROL-PLANE-026
  context "with a configured self repo in development" do
    let(:account) { create(:account) }

    before do
      allow(Rails).to receive(:env).and_return("development".inquiry)
      create(:project, account: account, owner: "viamin", repo: "paid")
      create(:tenant_setting, account: account, self_repo_full_name: "viamin/paid")
    end

    it "scans through the shared service path with the self-repo project" do
      scan = instance_double(Development::PgHeroOverview::Scan, call:
        Development::PgHeroOverview::Scan::Result.new(
          skipped: false, created: 0, updated: 0, reopened: 0, closed: 0, deferred: 0,
          deferred_keys: [], incomplete_categories: [], findings: 0))
      allow(Development::PgHeroOverview::Scan).to receive(:new).and_return(scan)

      described_class.perform_now

      expect(Development::PgHeroOverview::Scan).to have_received(:new) do |project:, **|
        expect(project.full_name).to eq("viamin/paid")
      end
      expect(scan).to have_received(:call)
    end
  end

  private

  def enqueued_jobs_count_for(job_class)
    ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == job_class }
  end
end
