# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadPerformance::RecordMeasurements do
  let(:project) { create(:project, screenshot_settings: { "enabled" => true }) }
  let(:agent_run) do
    create(:agent_run,
      project: project,
      branch_name: "paid/perf",
      pull_request_number: 42,
      result_commit_sha: "abc1234def5678")
  end

  let(:document) do
    {
      "captured_at" => "2026-08-23T18:04:11Z",
      "viewport" => { "width" => 1280, "height" => 900 },
      "routes" => {
        "dashboard" => {
          "path" => "/dashboard",
          "http_status" => 200,
          "samples" => 3,
          "metrics" => {
            "ttfb_ms" => { "median" => 90, "min" => 80, "max" => 120, "values" => [ 80, 90, 120 ] },
            "load_ms" => { "median" => 810, "min" => 780, "max" => 903, "values" => [ 780, 810, 903 ] },
            "lcp_ms" => { "median" => 640, "min" => 615, "max" => 701, "values" => [ 615, 640, 701 ] }
          }
        }
      }
    }
  end

  # @spec PAGE-LOAD-LEDGER-001
  it "persists one measurement per route with medians, samples, viewport and provenance" do
    measurements = described_class.call(agent_run: agent_run, document: document)

    expect(measurements.size).to eq(1)
    expect(measurements.first).to have_attributes(
      account_id: project.account_id,
      project_id: project.id,
      agent_run_id: agent_run.id,
      pull_request_number: 42,
      commit_sha: "abc1234def5678",
      route_name: "dashboard",
      route_path: "/dashboard",
      http_status: 200,
      ttfb_ms: 90,
      load_ms: 810,
      lcp_ms: 640,
      sample_count: 3,
      viewport_width: 1280,
      viewport_height: 900,
      source: "screenshot_capture"
    )
    expect(measurements.first.samples.dig("load_ms", "values")).to eq([ 780, 810, 903 ])
  end

  # @spec PAGE-LOAD-MEASURE-005
  it "records metrics absent from the document as null" do
    measurement = described_class.call(agent_run: agent_run, document: document).first

    expect(measurement.fcp_ms).to be_nil
    expect(measurement.dcl_ms).to be_nil
  end

  # @spec PAGE-LOAD-LEDGER-003
  it "replaces the earlier measurement when the same commit is captured again" do
    described_class.call(agent_run: agent_run, document: document)
    updated = document.deep_dup
    updated["routes"]["dashboard"]["metrics"]["load_ms"]["median"] = 999

    described_class.call(agent_run: agent_run, document: updated)

    rows = PageLoadMeasurement.where(project: project, pull_request_number: 42, route_name: "dashboard")
    expect(rows.size).to eq(1)
    expect(rows.first.load_ms).to eq(999)
  end

  # @spec PAGE-LOAD-MEASURE-011
  it "records a single-sample route without inventing a spread" do
    document["routes"]["dashboard"]["samples"] = 1
    document["routes"]["dashboard"]["metrics"]["load_ms"] = { "median" => 810, "min" => 810, "max" => 810, "values" => [ 810 ] }

    measurement = described_class.call(agent_run: agent_run, document: document).first

    expect(measurement.sample_count).to eq(1)
    expect(measurement.samples.dig("load_ms", "values")).to eq([ 810 ])
  end

  # @spec PAGE-LOAD-MEASURE-008
  it "records nothing when the document is missing" do
    expect { described_class.call(agent_run: agent_run, document: nil) }
      .not_to change(PageLoadMeasurement, :count)
  end

  # @spec PAGE-LOAD-MEASURE-008
  it "records nothing when the document carries no routes" do
    expect { described_class.call(agent_run: agent_run, document: { "routes" => {} }) }
      .not_to change(PageLoadMeasurement, :count)
  end
end
