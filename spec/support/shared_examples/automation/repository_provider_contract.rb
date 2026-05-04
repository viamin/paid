# frozen_string_literal: true

# Shared examples verifying that a concrete RepositoryProvider
# implementation satisfies the interface contract. Include this group in
# specs for every adapter (GitHub, GitLab, …) to guarantee return-type
# and error-handling parity.
#
# Expected `let` bindings the including spec must supply:
#
#   adapter       — an instance of the implementation class
#   repo          — a String repo identifier (e.g. "acme/widgets")
#   pr_number     — an Integer PR number whose fetch succeeds
#   ref           — a String git ref whose check-run fetch succeeds
#   label_name    — a String label name for add/remove tests
#   comment_body  — a String body for add_comment
#   stub_expected_provider_failure
#                 — a lambda that stubs an expected provider-side failure
#   invoke_expected_provider_failure
#                 — a lambda that performs the adapter call expected to
#                   raise ProviderError after translation
#   stub_missing_label_provider_failure
#                 — a lambda that stubs the provider's "label already
#                   absent" failure for remove_label
#   stub_already_merged_pull_request
#                 — a lambda that stubs the provider's response for
#                   merging an already-merged PR (must succeed, not raise)
#   provider_failure_message
#                 — the expected translated ProviderError message
#
# The adapter's underlying client should be stubbed to return valid
# data for the given repo/pr_number/ref combination.
RSpec.shared_examples "a RepositoryProvider implementation" do
  it "includes the RepositoryProvider module" do
    expect(adapter.class.ancestors).to include(Automation::Providers::RepositoryProvider)
  end

  describe "#fetch_pull_request" do
    it "returns a Data::PullRequest" do
      result = adapter.fetch_pull_request(repo: repo, number: pr_number)

      expect(result).to be_a(Automation::Providers::Data::PullRequest)
    end

    it "normalizes state to a symbol from PullRequest::STATES" do
      result = adapter.fetch_pull_request(repo: repo, number: pr_number)

      expect(Automation::Providers::Data::PullRequest::STATES).to include(result.state)
    end

    it "downcases author_login" do
      result = adapter.fetch_pull_request(repo: repo, number: pr_number)
      next if result.author_login.nil?

      expect(result.author_login).to eq(result.author_login.downcase)
    end

    it "returns labels as an Array of Strings" do
      result = adapter.fetch_pull_request(repo: repo, number: pr_number)

      expect(result.labels).to be_an(Array)
      expect(result.labels).to all(be_a(String))
    end
  end

  describe "#list_pull_requests" do
    it "returns an Array of Data::PullRequest" do
      result = adapter.list_pull_requests(repo: repo)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::PullRequest))
    end

    it "accepts and forwards the state filter" do
      result = adapter.list_pull_requests(repo: repo, state: :open)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::PullRequest))
    end

    it "accepts and forwards head and base filters" do
      result = adapter.list_pull_requests(repo: repo, head: "owner:feature", base: "main")

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::PullRequest))
    end
  end

  describe "#fetch_pull_request_files" do
    it "returns an Array of String paths" do
      result = adapter.fetch_pull_request_files(repo: repo, number: pr_number)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(String))
    end
  end

  describe "#fetch_check_runs" do
    it "returns an Array of Data::CheckRun" do
      result = adapter.fetch_check_runs(repo: repo, ref: ref)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::CheckRun))
      result.each { |run| expect(Automation::Providers::Data::CheckRun::STATUSES).to include(run.status) }
    end
  end

  describe "#add_labels" do
    it "does not raise for a valid label list" do
      expect { adapter.add_labels(repo: repo, number: pr_number, labels: [ label_name ]) }
        .not_to raise_error
    end
  end

  describe "#remove_label" do
    it "does not raise (idempotent)" do
      expect { adapter.remove_label(repo: repo, number: pr_number, label: label_name) }
        .not_to raise_error
    end

    it "swallows the provider's missing-label error" do
      stub_missing_label_provider_failure

      expect { adapter.remove_label(repo: repo, number: pr_number, label: label_name) }
        .not_to raise_error
    end
  end

  describe "#add_comment" do
    it "returns a Data::Comment" do
      result = adapter.add_comment(repo: repo, number: pr_number, body: comment_body)

      expect(result).to be_a(Automation::Providers::Data::Comment)
      expect(result.body).to eq(comment_body)
    end
  end

  describe "#mark_ready_for_review" do
    it "does not raise" do
      expect { adapter.mark_ready_for_review(repo: repo, number: pr_number) }
        .not_to raise_error
    end
  end

  describe "#merge_pull_request" do
    it "returns a Data::MergeResult" do
      result = adapter.merge_pull_request(repo: repo, number: pr_number, method: :squash)

      expect(result).to be_a(Automation::Providers::Data::MergeResult)
      expect(result.merged).to be(true).or be(false)
    end

    it "is idempotent when the PR is already merged" do
      stub_already_merged_pull_request

      result = adapter.merge_pull_request(repo: repo, number: pr_number, method: :squash)

      expect(result).to be_a(Automation::Providers::Data::MergeResult)
    end
  end

  describe "expected provider failures" do
    it "translates them into RepositoryProvider::ProviderError" do
      stub_expected_provider_failure

      expect(&invoke_expected_provider_failure).to raise_error(
        Automation::Providers::RepositoryProvider::ProviderError,
        provider_failure_message
      )
    end
  end
end
