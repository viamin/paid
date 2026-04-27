# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe DependabotAutoMergeJob do
  let(:project) { create(:project, auto_merge_mode: "dependabot_only") }
  let(:client) { instance_double(GithubClient) }

  let(:dependabot_pr) do
    OpenStruct.new(
      number: 42,
      title: "Bump rails from 7.0.0 to 7.1.0",
      user: OpenStruct.new(login: "dependabot[bot]"),
      head: OpenStruct.new(sha: "def456"),
      merged_at: nil,
      mergeable: true
    )
  end

  let(:green_checks) do
    [ { conclusion: "success", name: "ci" } ]
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      pull_requests: [ dependabot_pr ],
      pull_request: dependabot_pr,
      check_runs_for_ref: green_checks,
      combined_status: { state: "success", total_count: 1 }
    )
    allow(client).to receive(:merge_pull_request)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:add_comment)
  end

  describe "#perform" do
    it "merges a Dependabot PR when all conditions are met" do
      described_class.perform_now(project.id)

      expect(client).to have_received(:pull_requests).with(project.full_name, state: "open")
      expect(client).to have_received(:pull_request).with(project.full_name, 42)
      expect(client).to have_received(:merge_pull_request).with(
        project.full_name, 42, merge_method: project.merge_method
      )
      expect(client).to have_received(:add_labels_to_issue).with(
        project.full_name, 42, [ "paid-auto-merged-dependabot" ]
      )
      expect(client).to have_received(:add_comment)
    end

    it "skips when project has auto_merge_mode off" do
      project.update!(auto_merge_mode: "off")

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when CI checks are not green" do
      allow(client).to receive(:check_runs_for_ref).and_return(
        [ { conclusion: "failure", name: "ci" } ]
      )

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when CI checks are pending (no conclusion)" do
      allow(client).to receive(:check_runs_for_ref).and_return(
        [ { conclusion: nil, name: "ci" } ]
      )

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when PR is not mergeable" do
      dependabot_pr.mergeable = false

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when PR is not authored by Dependabot" do
      human_pr = OpenStruct.new(
        number: 43,
        title: "Fix bug",
        user: OpenStruct.new(login: "viamin"),
        head: OpenStruct.new(sha: "aaa111"),
        merged_at: nil,
        mergeable: true
      )
      allow(client).to receive_messages(pull_requests: [ human_pr ], pull_request: human_pr)

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when PR is already merged" do
      merged_pr = OpenStruct.new(
        number: 42,
        title: "Bump rails from 7.0.0 to 7.1.0",
        user: OpenStruct.new(login: "dependabot[bot]"),
        head: OpenStruct.new(sha: "def456"),
        merged_at: Time.current,
        mergeable: true
      )
      allow(client).to receive_messages(pull_requests: [ merged_pr ], pull_request: merged_pr)

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when no Dependabot PRs are found" do
      allow(client).to receive(:pull_requests).and_return([])

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "accepts a specific pr_number parameter" do
      described_class.perform_now(project.id, pr_number: 42)

      expect(client).to have_received(:pull_request).with(project.full_name, 42)
      expect(client).to have_received(:merge_pull_request)
    end

    it "accepts dependabot-preview[bot] as author" do
      preview_pr = OpenStruct.new(
        number: 44,
        title: "Bump nokogiri from 1.14.0 to 1.15.0",
        user: OpenStruct.new(login: "dependabot-preview[bot]"),
        head: OpenStruct.new(sha: "ggg789"),
        merged_at: nil,
        mergeable: true
      )
      allow(client).to receive_messages(pull_requests: [ preview_pr ], pull_request: preview_pr)

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
    end

    it "handles expected merge failures gracefully" do
      allow(client).to receive(:merge_pull_request).and_raise(
        GithubClient::ApiError.new("Merge conflict", status: 409)
      )

      expect { described_class.perform_now(project.id) }.not_to raise_error
    end

    it "skips when project is not found" do
      result = described_class.perform_now(999_999)

      expect(result).to be_nil
      expect(client).not_to have_received(:merge_pull_request)
    end

    it "treats skipped/neutral check conclusions as passing" do
      allow(client).to receive(:check_runs_for_ref).and_return([
        { conclusion: "success", name: "ci" },
        { conclusion: "skipped", name: "optional-check" },
        { conclusion: "neutral", name: "info-check" }
      ])

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
    end

    it "merges when no CI checks exist and combined status is success" do
      allow(client).to receive_messages(check_runs_for_ref: [], combined_status: { state: "success", total_count: 1 })

      described_class.perform_now(project.id)

      expect(client).to have_received(:combined_status)
      expect(client).to have_received(:merge_pull_request)
    end

    it "merges when no CI checks or statuses exist (no CI configured)" do
      allow(client).to receive_messages(check_runs_for_ref: [], combined_status: { state: "pending", total_count: 0 })

      described_class.perform_now(project.id)

      expect(client).to have_received(:combined_status)
      expect(client).to have_received(:merge_pull_request)
    end

    it "skips when no CI checks exist but combined status is pending with statuses" do
      allow(client).to receive_messages(check_runs_for_ref: [], combined_status: { state: "pending", total_count: 2 })

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when no CI checks exist and combined status is failure" do
      allow(client).to receive_messages(check_runs_for_ref: [], combined_status: { state: "failure", total_count: 1 })

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when no CI checks exist and combined status is error" do
      allow(client).to receive_messages(check_runs_for_ref: [], combined_status: { state: "error", total_count: 1 })

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "merges when mode is all" do
      project.update!(auto_merge_mode: "all")

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
    end

    it "falls back to combined status when check_runs returns 403 and status is green" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Resource not accessible by personal access token", status: 403)
      )
      allow(client).to receive(:combined_status).and_return(state: "success", total_count: 1)

      described_class.perform_now(project.id)

      expect(client).to have_received(:combined_status).with(project.full_name, dependabot_pr.head.sha)
      expect(client).to have_received(:merge_pull_request)
    end

    it "skips when check_runs returns 403 and combined status is not green" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Resource not accessible by personal access token", status: 403)
      )
      allow(client).to receive(:combined_status).and_return(state: "pending", total_count: 2)

      described_class.perform_now(project.id)

      expect(client).to have_received(:combined_status).with(project.full_name, dependabot_pr.head.sha)
      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when check_runs fails with a non-403 error" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::Error.new("Network timeout")
      )

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "raises when check_runs fails with a server error" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Internal Server Error", status: 500)
      )

      expect { described_class.perform_now(project.id) }.to raise_error(GithubClient::ApiError)
    end
  end
end
