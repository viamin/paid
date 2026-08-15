# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec AUTO-MERGE-003
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

    it "skips when PR has the paid-skip-auto-merge label" do
      labeled_pr = OpenStruct.new(
        number: 42,
        title: "Bump rails from 7.0.0 to 7.1.0",
        user: OpenStruct.new(login: "dependabot[bot]"),
        head: OpenStruct.new(sha: "def456"),
        merged_at: nil,
        mergeable: true,
        labels: [ OpenStruct.new(name: "paid-skip-auto-merge") ]
      )
      allow(client).to receive_messages(pull_requests: [ labeled_pr ], pull_request: labeled_pr)

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
      allow(client).to receive(:pull_requests).and_return([ human_pr ])

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
      allow(client).to receive(:pull_requests).and_return([ merged_pr ])

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "merges the second PR when the first has failing CI" do
      failing_pr = OpenStruct.new(
        number: 99,
        title: "Bump a from 1.0 to 2.0",
        user: OpenStruct.new(login: "dependabot[bot]"),
        head: OpenStruct.new(sha: "fail123"),
        merged_at: nil,
        mergeable: true
      )
      allow(client).to receive(:pull_requests).and_return([ failing_pr, dependabot_pr ])
      allow(client).to receive(:pull_request).and_return(failing_pr, dependabot_pr)
      allow(client).to receive(:check_runs_for_ref) do |_repo, sha|
        sha == "fail123" ? [ { conclusion: "failure", name: "ci" } ] : green_checks
      end

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request).with(
        project.full_name, 42, merge_method: project.merge_method
      )
    end

    it "stops after the first successful merge" do
      green_pr_2 = OpenStruct.new(
        number: 100,
        title: "Bump b from 2.0 to 3.0",
        user: OpenStruct.new(login: "dependabot[bot]"),
        head: OpenStruct.new(sha: "green456"),
        merged_at: nil,
        mergeable: true
      )
      allow(client).to receive(:pull_requests).and_return([ dependabot_pr, green_pr_2 ])
      allow(client).to receive(:pull_request).and_return(dependabot_pr, green_pr_2)

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request).once
      expect(client).to have_received(:merge_pull_request).with(
        project.full_name, 42, merge_method: project.merge_method
      )
    end

    it "fetches full PR lazily and skips unneeded fetches after merge" do
      unmergeable_pr = OpenStruct.new(
        number: 50,
        title: "Bump c from 3.0 to 4.0",
        user: OpenStruct.new(login: "dependabot[bot]"),
        head: OpenStruct.new(sha: "conflict789"),
        merged_at: nil,
        mergeable: false
      )
      allow(client).to receive(:pull_requests).and_return([ unmergeable_pr, dependabot_pr ])
      allow(client).to receive(:pull_request).and_return(unmergeable_pr, dependabot_pr)

      described_class.perform_now(project.id)

      expect(client).to have_received(:pull_request).with(project.full_name, 50)
      expect(client).to have_received(:pull_request).with(project.full_name, 42)
      expect(client).to have_received(:merge_pull_request).once
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

    context "with a configured PAT fallback" do
      let(:project) { create(:project, :with_github_installation, auto_merge_mode: "dependabot_only") }
      let(:fallback_token) { create(:github_token, :with_workflow_scope, account: project.account) }
      let(:fallback_client) { instance_double(GithubClient) }

      before do
        project.update!(git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback_token)
        allow(Github::AppInstallation).to receive(:token_for).and_return("ghs_app_token")
        allow(GithubClient).to receive(:new) do |token:, **|
          token == fallback_token.token ? fallback_client : client
        end
        allow(fallback_client).to receive(:merge_pull_request)
        allow(fallback_client).to receive(:add_labels_to_issue)
        allow(fallback_client).to receive(:add_comment)
      end

      it "retries workflow-permission merge failures with the fallback client" do
        allow(client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(
            "refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission",
            status: 403
          )
        )

        described_class.perform_now(project.id)

        expect(fallback_client).to have_received(:merge_pull_request).with(
          project.full_name, 42, merge_method: project.merge_method
        )
        expect(fallback_client).to have_received(:add_labels_to_issue).with(
          project.full_name, 42, [ "paid-auto-merged-dependabot" ]
        )
        expect(fallback_client).to have_received(:add_comment)
      end

      it "handles terminal fallback merge rejection without raising" do
        rejection = "refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission"
        allow(client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(rejection, status: 403)
        )
        allow(fallback_client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(rejection, status: 403)
        )

        expect { described_class.perform_now(project.id) }.not_to raise_error
      end

      it "records terminal fallback merge rejection on the synced PR row" do
        issue = create(:issue, :pull_request, project: project, github_number: 42)
        rejection = "refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission"
        allow(client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(rejection, status: 403)
        )
        allow(fallback_client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(rejection, status: 403)
        )

        described_class.perform_now(project.id)

        expect(issue.reload).to be_merge_permission_rejected
        expect(issue.merge_permission_rejection_reason).to eq(rejection)
      end

      it "skips merge attempts while a permission rejection is cooling down" do
        create(
          :issue,
          :pull_request,
          project: project,
          github_number: 42,
          merge_permission_rejected_at: 1.hour.ago,
          merge_permission_rejection_reason: "missing workflows permission"
        )

        described_class.perform_now(project.id)

        expect(client).not_to have_received(:check_runs_for_ref)
        expect(client).not_to have_received(:merge_pull_request)
        expect(fallback_client).not_to have_received(:merge_pull_request)
      end

      it "clears stale permission rejection after a successful fallback merge" do
        issue = create(
          :issue,
          :pull_request,
          project: project,
          github_number: 42,
          merge_permission_rejected_at: 7.hours.ago,
          merge_permission_rejection_reason: "missing workflows permission"
        )
        allow(client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(
            "refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission",
            status: 403
          )
        )

        described_class.perform_now(project.id)

        expect(issue.reload).not_to be_merge_permission_rejected
      end

      it "does not use the fallback client for non-permission API failures" do
        allow(client).to receive(:merge_pull_request).and_raise(
          GithubClient::ApiError.new(
            "server error mentioning `.github/workflows/ci.yml` without `workflows` permission",
            status: 500
          )
        )

        expect { described_class.perform_now(project.id) }.to raise_error(GithubClient::ApiError)
        expect(fallback_client).not_to have_received(:merge_pull_request)
      end
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

    it "merges via workflow_runs when check_runs is forbidden and workflow runs are green" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Resource not accessible by personal access token", status: 403)
      )
      allow(client).to receive(:workflow_runs_for_sha).and_return([
        { conclusion: "success", name: "ci.yml" }
      ])

      described_class.perform_now(project.id)

      expect(client).to have_received(:workflow_runs_for_sha).with(project.full_name, dependabot_pr.head.sha)
      expect(client).to have_received(:merge_pull_request)
    end

    it "skips via workflow_runs when check_runs is forbidden and any workflow run failed" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive(:workflow_runs_for_sha).and_return([
        { conclusion: "success", name: "lint.yml" },
        { conclusion: "failure", name: "test.yml" }
      ])

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when check_runs is forbidden, workflow runs are green, and commit statuses fail" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive_messages(
        workflow_runs_for_sha: [
          { conclusion: "success", name: "lint.yml" },
          { conclusion: "success", name: "test.yml" }
        ],
        combined_status: { state: "failure", total_count: 1 }
      )

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips via workflow_runs when check_runs is forbidden and a workflow run is still in progress" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive(:workflow_runs_for_sha).and_return([
        { conclusion: "success", name: "lint.yml", status: "completed" },
        { conclusion: nil, name: "test.yml", status: "in_progress" }
      ])

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "falls through to combined status when check_runs is forbidden and workflow_runs is empty" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive_messages(workflow_runs_for_sha: [], combined_status: { state: "success", total_count: 1 })

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
    end

    it "skips when check_runs is forbidden, workflow_runs is empty, and combined_status reports no contexts" do
      # Safety regression test: previously this case would merge by treating
      # "pending + 0 contexts" as "no CI configured", even though the Checks
      # API was forbidden so we never confirmed the absence of check runs.
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive_messages(workflow_runs_for_sha: [], combined_status: { state: "pending", total_count: 0 })

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when check_runs is forbidden and combined_status reports a non-success state" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive_messages(workflow_runs_for_sha: [], combined_status: { state: "pending", total_count: 2 })

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "skips when both check_runs and workflow_runs are forbidden and no statuses are configured" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive(:workflow_runs_for_sha).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive(:combined_status).and_return(state: "pending", total_count: 0)

      described_class.perform_now(project.id)

      expect(client).not_to have_received(:merge_pull_request)
    end

    it "merges when both check_runs and workflow_runs are forbidden but combined_status reports success" do
      allow(client).to receive(:check_runs_for_ref).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive(:workflow_runs_for_sha).and_raise(
        GithubClient::ApiError.new("Forbidden", status: 403)
      )
      allow(client).to receive(:combined_status).and_return(state: "success", total_count: 1)

      described_class.perform_now(project.id)

      expect(client).to have_received(:merge_pull_request)
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
