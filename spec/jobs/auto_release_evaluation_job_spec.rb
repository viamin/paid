# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe AutoReleaseEvaluationJob do
  let(:project) { create(:project, auto_release_granularity: "all") }
  let(:client) { instance_double(GithubClient) }

  let(:pr_data) do
    OpenStruct.new(
      number: 100,
      title: "chore(main): release 1.1.0",
      user: OpenStruct.new(login: "github-actions[bot]"),
      labels: [ OpenStruct.new(name: "autorelease: pending") ],
      head: OpenStruct.new(sha: "abc123"),
      merged_at: nil
    )
  end

  let(:manifest_content) do
    OpenStruct.new(content: Base64.encode64('{ ".": "1.0.0" }'))
  end

  let(:green_checks) do
    [ { conclusion: "success", name: "ci" } ]
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      pull_requests: [ pr_data ],
      pull_request: pr_data,
      contents: manifest_content,
      check_runs_for_ref: green_checks,
      combined_status: { state: "success", total_count: 1 }
    )
    allow(client).to receive(:merge_pull_request)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:add_comment)
  end

  describe "#perform" do
    it "merges a release PR when all conditions are met" do
      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request).with(
        project.full_name, 100, merge_method: project.merge_method
      )
      expect(client).to have_received(:add_labels_to_issue).with(
        project.full_name, 100, [ "paid-auto-released" ]
      )
      expect(client).to have_received(:add_comment)
    end

    it "skips when project has auto_release_granularity off" do
      project.update!(auto_release_granularity: "off")

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when bump type exceeds granularity (minor bump with patch_only)" do
      project.update!(auto_release_granularity: "patch_only")

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "merges patch bumps with patch_only granularity" do
      project.update!(auto_release_granularity: "patch_only")
      pr_data_patch = OpenStruct.new(
        number: 100,
        title: "chore(main): release 1.0.1",
        user: OpenStruct.new(login: "github-actions[bot]"),
        labels: [ OpenStruct.new(name: "autorelease: pending") ],
        head: OpenStruct.new(sha: "abc123"),
        merged_at: nil
      )
      allow(client).to receive_messages(pull_requests: [ pr_data_patch ], pull_request: pr_data_patch)

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
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

    it "falls back to combined status when check_runs returns 403 and status is green" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Resource not accessible by personal access token", status: 403)
      )
      allow(client).to receive(:combined_status).and_return(state: "success", total_count: 1)

      described_class.perform_now(project.id)

      expect(client).to have_received(:combined_status).with(project.full_name, pr_data.head.sha)
      expect(client).to have_received(:merge_pull_request)
    end

    it "skips when check_runs returns 403 and combined status is not green" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Resource not accessible by personal access token", status: 403)
      )
      allow(client).to receive(:combined_status).and_return(state: "pending", total_count: 2)

      described_class.perform_now(project.id)

      expect(client).to have_received(:combined_status).with(project.full_name, pr_data.head.sha)
      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when no release PR is found" do
      allow(client).to receive(:pull_requests).and_return([])

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "accepts a specific pr_number parameter" do
      described_class.perform_now(project.id, pr_number: 100)

      expect(client).to have_received(:pull_request).with(project.full_name, 100)
      expect(client).to have_received(:merge_pull_request)
    end

    it "warns and skips when manifest lookup returns a non-file response" do
      allow(client).to receive(:contents).and_return([])
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now(project.id)

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "auto_release.fetch_version_failed",
          project_id: project.id,
          response_class: "Array"
        )
      )
      expect(client).not_to have_received(:merge_pull_request)
    end

    it "handles expected merge failures gracefully" do
      allow(client).to receive(:merge_pull_request).and_raise(
        GithubClient::ApiError.new("Merge conflict", status: 409)
      )

      expect { described_class.perform_now(project.id) }.not_to raise_error
    end

    context "with granularity matrix" do
      {
        "all" => { major: true, minor: true, patch: true },
        "major_only" => { major: true, minor: true, patch: true },
        "minor_only" => { major: false, minor: true, patch: true },
        "patch_only" => { major: false, minor: false, patch: true },
        "off" => { major: false, minor: false, patch: false }
      }.each do |granularity, bumps|
        bumps.each do |bump_type, should_merge|
          it "#{should_merge ? 'merges' : 'skips'} #{bump_type} bump with #{granularity} granularity" do
            project.update!(auto_release_granularity: granularity)

            version_map = { major: "2.0.0", minor: "1.1.0", patch: "1.0.1" }
            new_version = version_map[bump_type]

            pr = OpenStruct.new(
              number: 100,
              title: "chore(main): release #{new_version}",
              user: OpenStruct.new(login: "github-actions[bot]"),
              labels: [ OpenStruct.new(name: "autorelease: pending") ],
              head: OpenStruct.new(sha: "abc123"),
              merged_at: nil
            )
            allow(client).to receive_messages(pull_requests: [ pr ], pull_request: pr)

            described_class.perform_now(project.id)

            if should_merge
              expect(client).to have_received(:merge_pull_request)
            else
              expect(client).not_to have_received(:merge_pull_request)
            end
          end
        end
      end
    end
  end
end
