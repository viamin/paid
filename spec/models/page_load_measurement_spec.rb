# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadMeasurement do
  let(:project) { create(:project) }

  describe "persistence" do
    # @spec PAGE-LOAD-LEDGER-001
    it "records the route, its resolved path, status, medians, samples and viewport" do
      measurement = create(:page_load_measurement, project: project)

      expect(measurement.reload).to have_attributes(
        account_id: project.account_id,
        project_id: project.id,
        pull_request_number: 42,
        route_name: "dashboard",
        route_path: "/dashboard",
        http_status: 200,
        load_ms: 810,
        lcp_ms: 640,
        sample_count: 3,
        viewport_width: 1280,
        viewport_height: 900
      )
      expect(measurement.samples.dig("load_ms", "values")).to eq([ 780, 810, 903 ])
    end

    # @spec PAGE-LOAD-MEASURE-005
    it "keeps an unavailable paint metric null rather than zero" do
      measurement = create(:page_load_measurement, project: project, lcp_ms: nil, fcp_ms: nil)

      expect(measurement.reload.lcp_ms).to be_nil
      expect(measurement.reload.fcp_ms).to be_nil
    end

    # @spec PAGE-LOAD-LEDGER-003
    it "rejects a second measurement for the same project, pull request, commit and route" do
      create(:page_load_measurement, project: project)

      expect {
        create(:page_load_measurement, project: project)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # @spec PAGE-LOAD-LEDGER-003
    it "allows the same route at a different commit" do
      create(:page_load_measurement, project: project, commit_sha: "aaa1111")

      expect {
        create(:page_load_measurement, project: project, commit_sha: "bbb2222")
      }.not_to raise_error
    end
  end


  describe ".prune_older_than" do
    # @spec PAGE-LOAD-LEDGER-004
    it "deletes measurements captured before the cutoff and keeps newer ones" do
      old = create(:page_load_measurement, project: project, commit_sha: "old111", captured_at: 40.days.ago)
      kept = create(:page_load_measurement, project: project, commit_sha: "new222", captured_at: 2.days.ago)

      described_class.prune_older_than(30.days.ago)

      expect(described_class.where(id: old.id)).to be_empty
      expect(described_class.where(id: kept.id)).to be_present
    end
  end
end
