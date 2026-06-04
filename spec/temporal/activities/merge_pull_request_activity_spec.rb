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
      end

      it "delivers merge subscription notifications" do
        expect(IssueMergeSubscriptions::Deliver).to receive(:call)
          .with(issue: issue, event: :merged)

        activity.execute(project_id: project.id, pr_number: 42, issue_id: issue.id)
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
