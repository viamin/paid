# frozen_string_literal: true

require "rails_helper"

RSpec.describe PageLoadPerformance::ExportLedger do
  let(:project) { create(:project, owner: "acme", repo: "web", screenshot_settings: { "enabled" => true }) }
  let(:storage) { instance_double(Screenshots::Storage) }
  let(:uploaded) { {} }

  before do
    allow(ArtifactStorage).to receive(:configured?).and_return(true)
    allow(storage).to receive(:upload_document) do |key:, body:, **|
      uploaded[key] = body
      "https://s3.example.com/#{key}"
    end
  end

  def measurement(route: "dashboard", commit: "aaa1111", lcp: 640, captured_at: Time.current)
    create(:page_load_measurement,
      project: project, route_name: route, route_path: "/#{route}",
      commit_sha: commit, lcp_ms: lcp, captured_at: captured_at)
  end

  # @spec PAGE-LOAD-EXPORT-001
  it "writes one document per project under the screenshot namespace" do
    measurement

    described_class.call(project: project, storage: storage)

    expect(uploaded.keys).to eq([ "screenshots/acme/web/page-load-times.json" ])
  end

  # @spec PAGE-LOAD-EXPORT-002
  it "lists each route's measurements newest-first with a summary" do
    measurement(commit: "aaa1111", lcp: 600, captured_at: 3.hours.ago)
    measurement(commit: "bbb2222", lcp: 900, captured_at: 1.hour.ago)

    described_class.call(project: project, storage: storage)

    document = JSON.parse(uploaded.values.first)
    entries = document.dig("routes", "dashboard", "entries")
    expect(entries.map { |e| e["commit_sha"] }).to eq(%w[bbb2222 aaa1111])
    expect(document.dig("routes", "dashboard", "summary")).to include(
      "trailing_median_ms" => 750,
      "best_ms" => 600,
      "worst_ms" => 900
    )
  end

  # @spec PAGE-LOAD-EXPORT-002
  it "keeps only the 100 most recent measurements per route" do
    105.times { |i| measurement(commit: "sha#{i}", lcp: 600 + i, captured_at: i.hours.ago) }

    described_class.call(project: project, storage: storage)

    document = JSON.parse(uploaded.values.first)
    expect(document.dig("routes", "dashboard", "entries").size).to eq(100)
  end

  # @spec PAGE-LOAD-EXPORT-001
  it "regenerates the document from the record so a later capture rewrites it whole" do
    measurement(commit: "aaa1111", lcp: 600, captured_at: 2.hours.ago)
    described_class.call(project: project, storage: storage)

    measurement(commit: "bbb2222", lcp: 900, captured_at: 1.minute.ago)
    described_class.call(project: project, storage: storage)

    entries = JSON.parse(uploaded.values.first).dig("routes", "dashboard", "entries")
    expect(entries.map { |e| e["commit_sha"] }).to eq(%w[bbb2222 aaa1111])
  end

  # @spec PAGE-LOAD-EXPORT-002
  it "loads only the entries the document keeps, not the project's whole history" do
    120.times { |i| measurement(commit: "sha#{i}", lcp: 600 + i, captured_at: i.hours.ago) }

    loaded = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      loaded += 1 if payload[:name] == "PageLoadMeasurement Load"
    end
    described_class.call(project: project, storage: storage)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    entries = JSON.parse(uploaded.values.first).dig("routes", "dashboard", "entries")
    expect(entries.size).to eq(described_class::ENTRIES_PER_ROUTE)
    expect(loaded).to be <= 2
  end

  # @spec PAGE-LOAD-EXPORT-003
  it "skips the export when object storage is not configured" do
    allow(ArtifactStorage).to receive(:configured?).and_return(false)
    measurement

    expect(described_class.call(project: project, storage: nil)).to be_nil
    expect(uploaded).to be_empty
  end
end
