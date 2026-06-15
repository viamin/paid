# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::PrCycleTimeSeries do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  def create_merged_pr(project:, github_created_at:, github_updated_at:)
    create(:issue, :pull_request, :closed, project: project,
      pr_review_phase: "merged",
      github_created_at: github_created_at,
      github_updated_at: github_updated_at)
  end

  describe ".call" do
    context "with no merged PRs" do
      it "returns empty summary" do
        result = described_class.call(account: account)
        expect(result[:summary][:total_merged]).to eq(0)
        expect(result[:summary][:total_days]).to eq(0)
      end

      it "returns empty series data" do
        travel_to(Time.zone.local(2026, 6, 1, 12, 0, 0)) do
          result = described_class.call(account: account)
          expect(result[:series].all? { |s| s[:data].values.compact.empty? }).to be(true)
        end
      end
    end

    context "with merged PRs" do
      around do |example|
        travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run }
      end

      before do
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 8, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 11, 0, 0))
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 12, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 12, 16, 0, 0))
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 14, 8, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 14, 10, 30, 0))
      end

      it "counts total merged PRs" do
        result = described_class.call(account: account)
        expect(result[:summary][:total_merged]).to eq(4)
      end

      it "groups by merge date" do
        result = described_class.call(account: account)
        counts = result[:merged_counts]
        expect(counts[Date.new(2026, 6, 10)]).to eq(2)
        expect(counts[Date.new(2026, 6, 12)]).to eq(1)
        expect(counts[Date.new(2026, 6, 14)]).to eq(1)
      end

      it "computes avg and p50 for each day" do
        result = described_class.call(account: account)
        series_avg = result[:series].find { |s| s[:name] == "Average" }[:data]
        series_p50 = result[:series].find { |s| s[:name] == "Median (p50)" }[:data]

        avg_june10 = series_avg[Date.new(2026, 6, 10)]
        p50_june10 = series_p50[Date.new(2026, 6, 10)]
        expect(avg_june10).to eq(3.5)
        expect(p50_june10).to eq(3.5)

        avg_june12 = series_avg[Date.new(2026, 6, 12)]
        p50_june12 = series_p50[Date.new(2026, 6, 12)]
        expect(avg_june12).to eq(6.0)
        expect(p50_june12).to eq(6.0)
      end

      it "includes trend line data" do
        result = described_class.call(account: account)
        trend = result[:series].find { |s| s[:name] == "Trend" }[:data]
        expect(trend.values.compact).not_to be_empty
      end

      it "returns overall summary" do
        result = described_class.call(account: account)
        summary = result[:summary]
        expect(summary[:total_merged]).to eq(4)
        expect(summary[:total_days]).to eq(3)
        expect(summary[:overall_avg_hours]).to be > 0
        expect(summary[:overall_p50_hours]).to be > 0
      end
    end

    context "with outlier filtering" do
      around do |example|
        travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run }
      end

      before do
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 0, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 11, 10, 0, 0))
      end

      it "excludes outliers above cutoff" do
        result = described_class.call(account: account, outlier_cutoff_hours: 24)
        avg = result[:series].find { |s| s[:name] == "Average" }[:data]
        expect(avg[Date.new(2026, 6, 10)]).to eq(4.0)
        expect(avg[Date.new(2026, 6, 11)]).to be_nil
      end

      it "reports outliers removed" do
        result = described_class.call(account: account, outlier_cutoff_hours: 24)
        expect(result[:outlier_annotations]).to have_key(Date.new(2026, 6, 11))
        expect(result[:outlier_annotations][Date.new(2026, 6, 11)]).to eq(1)
      end

      it "includes outliers when cutoff is high" do
        result = described_class.call(account: account, outlier_cutoff_hours: 100)
        avg = result[:series].find { |s| s[:name] == "Average" }[:data]
        expect(avg[Date.new(2026, 6, 11)]).to eq(34.0)
      end
    end

    context "with time range filter" do
      around do |example|
        travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run }
      end

      before do
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 1, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 1, 14, 0, 0))
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
      end

      it "returns all data for cumulative" do
        result = described_class.call(account: account, time_range: "cumulative")
        expect(result[:summary][:total_merged]).to eq(2)
      end

      it "filters to 7 days" do
        result = described_class.call(account: account, time_range: "7d")
        expect(result[:summary][:total_merged]).to eq(1)
      end

      it "filters to 30 days" do
        result = described_class.call(account: account, time_range: "30d")
        expect(result[:summary][:total_merged]).to eq(2)
      end
    end

    context "with project scoping" do
      let(:project2) { create(:project, account: account) }

      around do |example|
        travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run }
      end

      before do
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
        create_merged_pr(project: project2,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 16, 0, 0))
      end

      it "scopes to single project when project_id is provided" do
        result = described_class.call(account: account, project_id: project.id)
        expect(result[:summary][:total_merged]).to eq(1)
      end

      it "includes all projects without project_id" do
        result = described_class.call(account: account)
        expect(result[:summary][:total_merged]).to eq(2)
      end
    end

    context "with PRs from another account" do
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      around do |example|
        travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run }
      end

      before do
        create_merged_pr(project: project,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
        create_merged_pr(project: other_project,
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
      end

      it "excludes PRs from other accounts" do
        result = described_class.call(account: account)
        expect(result[:summary][:total_merged]).to eq(1)
      end
    end

    context "with non-merged PRs" do
      around do |example|
        travel_to(Time.zone.local(2026, 6, 15, 12, 0, 0)) { example.run }
      end

      before do
        create(:issue, :pull_request, :closed, project: project,
          pr_review_phase: "draft",
          github_created_at: Time.zone.local(2026, 6, 10, 10, 0, 0),
          github_updated_at: Time.zone.local(2026, 6, 10, 14, 0, 0))
      end

      it "does not include non-merged PRs" do
        result = described_class.call(account: account)
        expect(result[:summary][:total_merged]).to eq(0)
      end
    end
  end
end
