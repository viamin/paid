# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MergePullRequestActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, merge_method: "squash", auto_merge_mode: "all") }
  let(:issue) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      pr_review_phase: "ready")
  end
  let(:provider) { instance_double(Automation::Providers::Github::RepositoryProvider) }

  before do
    allow(Automation::Providers::Resolver).to receive(:repository_for)
      .with(project)
      .and_return(provider)
  end

  describe "#execute" do
    context "when auto_merge is disabled" do
      before { project.update!(auto_merge_mode: "off") }

      it "returns skipped without calling the provider" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result).to include(merged: false, skipped: true)
        expect(Automation::Providers::Resolver).not_to have_received(:repository_for)
        expect(project.auto_merge_attempts.recent.first).to have_attributes(
          issue: issue,
          status: "skipped",
          reason_code: AutoMergeAttempts::Record::REASON_AUTO_MERGE_DISABLED
        )
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when issue has the paid-skip-auto-merge label" do
      before do
        issue.update!(labels: issue.labels + [ "paid-skip-auto-merge" ])
      end

      it "returns skipped without calling the provider" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result).to include(merged: false, skipped: true)
        expect(Automation::Providers::Resolver).not_to have_received(:repository_for)
        expect(project.auto_merge_attempts.recent.first).to have_attributes(
          issue: issue,
          status: "skipped",
          reason_code: AutoMergeAttempts::Record::REASON_SKIP_LABEL
        )
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "when PR is not yet merged" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:merge_result) do
        Automation::Providers::Data::MergeResult.new(merged: true, sha: "def456", message: "Merged")
      end

      before do
        allow(provider).to receive(:fetch_pull_request)
          .with(repo: project.full_name, number: 42)
          .and_return(pr_data)
        allow(provider).to receive(:merge_pull_request).and_return(merge_result)
        allow(provider).to receive(:add_labels)
        allow(provider).to receive(:add_comment)
      end

      it "merges the PR using the project's configured merge method" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).to have_received(:merge_pull_request)
          .with(repo: project.full_name, number: 42, method: :squash)
      end

      it "updates issue phase to merged" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("merged")
      end

      it "clears a prior merge-permission rejection recorded on the issue" do
        issue.update!(merge_permission_rejected_at: 7.hours.ago, merge_permission_rejection_reason: "stale")

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        issue.reload
        expect(issue.merge_permission_rejected?).to be(false)
        expect(issue.merge_permission_rejection_reason).to be_nil
      end

      it "adds the paid-auto-merged label" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).to have_received(:add_labels)
          .with(repo: project.full_name, number: 42, labels: [ described_class::PAID_AUTO_MERGED_LABEL ])
      end

      it "posts an auto-merge comment on the PR" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).to have_received(:add_comment)
          .with(repo: project.full_name, number: 42, body: described_class::AUTO_MERGE_COMMENT)
      end

      it "returns merged: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
        expect(project.auto_merge_attempts.recent.first).to have_attributes(
          issue: issue,
          actor_path: AutoMergeAttempts::Record::ACTOR_REVIEW_AUTO_MERGE,
          status: "merged"
        )
      end

      it "delivers merge subscription notifications" do
        expect(IssueMergeSubscriptions::Deliver).to receive(:call)
          .with(issue: issue, event: :merged)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
      end
    end

    context "when merging a PR that was escalated" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          pr_review_phase: "escalated",
          labels: [ "paid-generated", described_class::PAID_ESCALATED_LABEL ])
      end
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:merge_result) do
        Automation::Providers::Data::MergeResult.new(merged: true, sha: "def456", message: "Merged")
      end

      before do
        allow(provider).to receive(:fetch_pull_request)
          .with(repo: project.full_name, number: 42)
          .and_return(pr_data)
        allow(provider).to receive(:merge_pull_request).and_return(merge_result)
        allow(provider).to receive(:add_labels)
        allow(provider).to receive(:add_comment)
        allow(provider).to receive(:remove_label)
      end

      it "removes the paid-escalated label on the host" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).to have_received(:remove_label)
          .with(repo: project.full_name, number: 42, label: described_class::PAID_ESCALATED_LABEL)
      end

      it "strips the paid-escalated label from the issue's labels" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.labels).not_to include(described_class::PAID_ESCALATED_LABEL)
      end

      it "does not abort the merge when host label removal fails" do
        allow(provider).to receive(:remove_label)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, "boom")

        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
        expect(issue.reload.pr_review_phase).to eq("merged")
      end
    end

    context "when merging a PR that was not escalated" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:merge_result) do
        Automation::Providers::Data::MergeResult.new(merged: true, sha: "def456", message: "Merged")
      end

      before do
        allow(provider).to receive(:fetch_pull_request)
          .with(repo: project.full_name, number: 42)
          .and_return(pr_data)
        allow(provider).to receive(:merge_pull_request).and_return(merge_result)
        allow(provider).to receive(:add_labels)
        allow(provider).to receive(:add_comment)
        allow(provider).to receive(:remove_label)
      end

      it "does not call remove_label" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).not_to have_received(:remove_label)
      end
    end

    context "when PR is already merged" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :closed, draft: false,
          merged: true, mergeable: false, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: Time.current, url: "https://example.com/pr/42",
          raw_state: "closed"
        )
      end

      before do
        allow(provider).to receive(:fetch_pull_request)
          .with(repo: project.full_name, number: 42)
          .and_return(pr_data)
        allow(provider).to receive(:merge_pull_request)
        allow(provider).to receive(:add_labels)
        allow(provider).to receive(:add_comment)
      end

      it "skips the merge call" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).not_to have_received(:merge_pull_request)
      end

      it "still updates issue phase to merged" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("merged")
      end

      it "clears a prior merge-permission rejection recorded on the issue" do
        issue.update!(merge_permission_rejected_at: 7.hours.ago, merge_permission_rejection_reason: "stale")

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.merge_permission_rejected?).to be(false)
      end

      it "does not add the paid-auto-merged label (may have been merged manually)" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).not_to have_received(:add_labels)
      end

      it "does not post an auto-merge comment" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).not_to have_received(:add_comment)
      end

      it "delivers merge subscription notifications" do
        expect(IssueMergeSubscriptions::Deliver).to receive(:call)
          .with(issue: issue, event: :merged)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
      end
    end

    context "when labeling fails after merge" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:merge_result) do
        Automation::Providers::Data::MergeResult.new(merged: true, sha: "def456", message: "Merged")
      end

      before do
        allow(provider).to receive_messages(
          fetch_pull_request: pr_data,
          merge_pull_request: merge_result
        )
        allow(provider).to receive(:add_labels)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, "Not found")
        allow(provider).to receive(:add_comment)
      end

      it "does not raise and still returns merged: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
        expect(provider).to have_received(:add_labels)
      end
    end

    context "when commenting fails after merge" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:merge_result) do
        Automation::Providers::Data::MergeResult.new(merged: true, sha: "def456", message: "Merged")
      end

      before do
        allow(provider).to receive_messages(
          fetch_pull_request: pr_data,
          merge_pull_request: merge_result,
          add_labels: nil
        )
        allow(provider).to receive(:add_comment)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, "Not found")
      end

      it "does not raise and still returns merged: true" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
        expect(provider).to have_received(:add_comment)
      end
    end

    context "when merge fails with a provider error" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end

      before do
        allow(provider).to receive(:fetch_pull_request).and_return(pr_data)
        allow(provider).to receive(:merge_pull_request)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, "Merge conflict")
      end

      it "returns merged: false" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be false
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end

      it "does not add the label" do
        allow(provider).to receive(:add_labels)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).not_to have_received(:add_labels)
      end

      it "does not deliver merge subscription notifications" do
        expect(IssueMergeSubscriptions::Deliver).not_to receive(:call)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
      end
    end

    context "when merge fails with a GitHub App permission rejection" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:rejection_message) do
        "403 - refusing to allow a GitHub App to create or update workflow " \
          "`.github/workflows/ci.yml` without `workflows` permission"
      end
      let(:client) { instance_double(GithubClient) }

      before do
        allow(provider).to receive(:fetch_pull_request).and_return(pr_data)
        allow(provider).to receive(:merge_pull_request)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, rejection_message)
        allow(GithubClient).to receive(:new).and_return(client)
        allow(client).to receive(:recent_issue_comments).and_return([])
        allow(client).to receive(:add_comment)
      end

      it "returns merged: false" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be false
      end

      it "records the rejection on the issue" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        issue.reload
        expect(issue.merge_permission_rejected?).to be(true)
        expect(issue.merge_permission_rejection_reason).to eq(rejection_message)
        expect(project.auto_merge_attempts.recent.first).to have_attributes(
          issue: issue,
          status: "blocked",
          reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
          credential_mode: "pat"
        )
      end

      it "posts a comment explaining the actionable cause" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(client).to have_received(:add_comment) do |repo, number, body|
          expect(repo).to eq(project.full_name)
          expect(number).to eq(42)
          expect(body).to include("Auto-merge blocked: missing GitHub App permission")
          expect(body).to include("workflows")
        end
      end

      it "does not post a duplicate comment when one already exists" do
        existing = double(body: "<!-- paid: merge-permission-rejection --> earlier")
        allow(client).to receive(:recent_issue_comments).and_return([ existing ])

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(client).not_to have_received(:add_comment)
      end

      it "skips the next attempt within the cooldown window without calling the provider" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).to have_received(:fetch_pull_request).twice
        expect(provider).to have_received(:merge_pull_request).once
        expect(project.auto_merge_attempts.recent.first).to have_attributes(
          issue: issue,
          status: "skipped",
          reason_code: AutoMergeAttempts::Record::REASON_MERGE_PERMISSION_COOLDOWN
        )
      end

      it "still observes an out-of-band merge during the cooldown and clears the blocked state" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        merged_pr_data = Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :closed, draft: false,
          merged: true, mergeable: false, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: Time.current, url: "https://example.com/pr/42",
          raw_state: "closed"
        )
        allow(provider).to receive(:fetch_pull_request).and_return(merged_pr_data)

        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result[:merged]).to be true
        expect(provider).to have_received(:merge_pull_request).once
        expect(issue.reload.pr_review_phase).to eq("merged")
        expect(issue.merge_permission_rejected?).to be(false)
      end

      it "retries after the cooldown window has elapsed" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        travel (Issue::MERGE_PERMISSION_RETRY_COOLDOWN + 1.minute) do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
        end

        expect(provider).to have_received(:fetch_pull_request).twice
      end
    end

    context "when merge fails with a GitHub App permission rejection and PAT fallback is configured" do
      let(:fallback_token) { create(:github_token, account: project.account) }
      let(:project) do
        create(:project, :with_github_installation, merge_method: "squash", auto_merge_mode: "all")
      end
      let(:issue) do
        create(:issue, :pull_request, project: project, github_number: 42, pr_review_phase: "ready")
      end
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:rejection_message) do
        "403 - refusing to allow a GitHub App to create or update workflow " \
          "`.github/workflows/ci.yml` without `workflows` permission"
      end
      # Both the fallback token's client and (in the "also fails" context)
      # project.client's App credential resolve through GithubClient.new —
      # stubbed once here so identity doesn't depend on which GithubToken/
      # Project instance the activity happens to load internally.
      let(:client) { instance_double(GithubClient) }

      before do
        project.update!(git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback_token)
        allow(provider).to receive(:fetch_pull_request).and_return(pr_data)
        allow(provider).to receive(:merge_pull_request)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, rejection_message)
        allow(GithubClient).to receive(:new).and_return(client)
      end

      context "when the fallback merge succeeds" do
        before do
          allow(client).to receive(:merge_pull_request)
            .and_return({ merged: true, sha: "def456", message: "Merged" })
          allow(provider).to receive(:add_labels)
          allow(provider).to receive(:add_comment)
        end

        it "returns merged: true" do
          result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(result[:merged]).to be true
        end

        it "updates issue phase to merged" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(issue.reload.pr_review_phase).to eq("merged")
        end

        it "does not record a merge-permission rejection on the issue" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(issue.reload.merge_permission_rejected?).to be(false)
          expect(project.auto_merge_attempts.recent.first).to have_attributes(
            issue: issue,
            status: "merged",
            credential_mode: "pat_fallback"
          )
        end

        it "still labels and comments via the App-authenticated provider" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(provider).to have_received(:add_labels)
            .with(repo: project.full_name, number: 42, labels: [ described_class::PAID_AUTO_MERGED_LABEL ])
        end

        it "retries with the same repo, PR number, and merge method as the primary attempt" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(client).to have_received(:merge_pull_request)
            .with(project.full_name, 42, merge_method: "squash", commit_title: nil, commit_message: nil)
        end
      end

      context "when the fallback merge also hits a permission rejection" do
        before do
          allow(Github::AppInstallation).to receive(:token_for).and_return("fake-app-installation-token")
          allow(client).to receive(:merge_pull_request)
            .and_raise(GithubClient::Error, rejection_message)
          allow(client).to receive(:recent_issue_comments).and_return([])
          allow(client).to receive(:add_comment)
        end

        it "returns merged: false" do
          result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(result[:merged]).to be false
        end

        it "records the rejection on the issue" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(issue.reload.merge_permission_rejected?).to be(true)
          expect(project.auto_merge_attempts.recent.first).to have_attributes(
            issue: issue,
            status: "blocked",
            reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
            credential_mode: "pat_fallback"
          )
        end

        it "posts a comment noting the fallback credential also failed" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(client).to have_received(:add_comment) do |_repo, _number, body|
            expect(body).to include("PAT push-fallback credential also could not merge")
          end
        end
      end

      context "when the fallback merge fails transiently" do
        before do
          allow(Github::AppInstallation).to receive(:token_for).and_return("fake-app-installation-token")
          allow(client).to receive(:merge_pull_request)
            .and_raise(GithubClient::Error, "502 Bad Gateway")
          allow(client).to receive(:recent_issue_comments)
          allow(client).to receive(:add_comment)
        end

        it "returns merged: false and still records the primary permission rejection cooldown" do
          result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(result[:merged]).to be false
          expect(issue.reload.merge_permission_rejected?).to be(true)
          expect(issue.merge_permission_rejection_reason).to eq(rejection_message)
          expect(project.auto_merge_attempts.recent.first).to have_attributes(
            issue: issue,
            status: "blocked",
            reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
            credential_mode: "pat_fallback"
          )
        end

        it "does not post the merge-permission comment" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(client).not_to have_received(:recent_issue_comments)
          expect(client).not_to have_received(:add_comment)
        end

        it "skips the next merge attempt until the cooldown expires" do
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
          activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

          expect(provider).to have_received(:fetch_pull_request).twice
          expect(provider).to have_received(:merge_pull_request).once
          expect(client).to have_received(:merge_pull_request).once
        end
      end
    end

    context "when the pre-merge fetch raises a provider error" do
      before do
        allow(provider).to receive(:fetch_pull_request)
          .and_raise(Automation::Providers::RepositoryProvider::ProviderError, "no GitHub client")
      end

      it "returns merged: false with the error instead of raising" do
        result = activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(result).to include(merged: false, pr_number: 42, error: "no GitHub client")
      end

      it "does not update issue phase" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("ready")
      end
    end

    context "with different merge methods" do
      let(:pr_data) do
        Automation::Providers::Data::PullRequest.new(
          number: 42, title: "Test", body: nil, state: :open, draft: false,
          merged: false, mergeable: true, head_sha: "abc", head_ref: "feature",
          base_ref: "main", author_login: "user", labels: [], created_at: Time.current,
          updated_at: Time.current, merged_at: nil, url: "https://example.com/pr/42",
          raw_state: "open"
        )
      end
      let(:merge_result) do
        Automation::Providers::Data::MergeResult.new(merged: true, sha: "def456", message: "Merged")
      end

      before do
        project.update!(merge_method: "rebase")
        allow(provider).to receive_messages(
          fetch_pull_request: pr_data,
          merge_pull_request: merge_result,
          add_labels: nil,
          add_comment: nil
        )
      end

      it "uses the project's configured merge method" do
        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)

        expect(provider).to have_received(:merge_pull_request)
          .with(repo: project.full_name, number: 42, method: :rebase)
      end
    end
  end
end
