# frozen_string_literal: true

# Shared examples verifying that a concrete WorkItemProvider
# implementation satisfies the interface contract.
#
# Expected `let` bindings:
#
#   adapter        — an instance of the implementation class
#   repo           — a String repo identifier
#   issue_number   — an Integer/String issue number whose fetch succeeds
#   label_name     — a String label name for add/remove tests
#   comment_body   — a String body for add_comment
#   stub_expected_provider_failure
#                 — a lambda that stubs an expected provider-side failure
#   invoke_expected_provider_failure
#                 — a lambda that performs the adapter call expected to
#                   raise ProviderError after translation
#   stub_missing_label_provider_failure
#                 — a lambda that stubs the provider's "label already
#                   absent" failure for remove_label
#   invoke_list_issues_with_state_filter
#                 — a lambda that performs #list_issues with a state
#                   filter and asserts the provider client receives it
#   invoke_list_issues_with_labels_filter
#                 — a lambda that performs #list_issues with label
#                   filters and asserts the provider client receives them
#   invoke_list_issues_with_assignees_filter
#                 — a lambda that performs #list_issues with assignee
#                   filters and asserts the provider client receives them
#   provider_failure_message
#                 — the expected translated ProviderError message
#
# The adapter's underlying client should be stubbed to return valid
# data for the given repo/issue_number combination.
RSpec.shared_examples "a WorkItemProvider implementation" do
  it "includes the WorkItemProvider module" do
    expect(adapter.class.ancestors).to include(Automation::Providers::WorkItemProvider)
  end

  describe "#fetch_issue" do
    it "returns a Data::Issue" do
      result = adapter.fetch_issue(repo: repo, number: issue_number)

      expect(result).to be_a(Automation::Providers::Data::Issue)
    end

    it "normalizes state to a symbol from Issue::STATES" do
      result = adapter.fetch_issue(repo: repo, number: issue_number)

      expect(Automation::Providers::Data::Issue::STATES).to include(result.state)
    end

    it "returns labels as an Array of Strings" do
      result = adapter.fetch_issue(repo: repo, number: issue_number)

      expect(result.labels).to be_an(Array)
      expect(result.labels).to all(be_a(String))
    end

    it "returns dependencies as an Array" do
      result = adapter.fetch_issue(repo: repo, number: issue_number)

      expect(result.dependencies).to be_an(Array)
    end
  end

  describe "#list_issues" do
    it "returns an Array of Data::Issue" do
      result = adapter.list_issues(repo: repo)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::Issue))
    end

    it "accepts and forwards the state filter" do
      result = invoke_list_issues_with_state_filter.call

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::Issue))
    end

    it "accepts and forwards the labels filter" do
      result = invoke_list_issues_with_labels_filter.call

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::Issue))
    end

    it "accepts and forwards the assignees filter" do
      result = invoke_list_issues_with_assignees_filter.call

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::Issue))
    end
  end

  describe "#fetch_issue_comments" do
    it "returns an Array of Data::Comment" do
      result = adapter.fetch_issue_comments(repo: repo, number: issue_number)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::Comment))
    end
  end

  describe "#fetch_issue_timeline" do
    it "returns an Array of Data::TimelineEvent" do
      result = adapter.fetch_issue_timeline(repo: repo, number: issue_number)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::TimelineEvent))
    end
  end

  describe "#create_issue" do
    it "returns a Data::Issue" do
      result = adapter.create_issue(repo: repo, title: "Test issue")

      expect(result).to be_a(Automation::Providers::Data::Issue)
    end
  end

  describe "#add_labels" do
    it "does not raise for a valid label list" do
      expect { adapter.add_labels(repo: repo, number: issue_number, labels: [ label_name ]) }
        .not_to raise_error
    end
  end

  describe "#remove_label" do
    it "does not raise (idempotent)" do
      expect { adapter.remove_label(repo: repo, number: issue_number, label: label_name) }
        .not_to raise_error
    end

    it "swallows the provider's missing-label error" do
      stub_missing_label_provider_failure

      expect { adapter.remove_label(repo: repo, number: issue_number, label: label_name) }
        .not_to raise_error
    end
  end

  describe "#add_comment" do
    it "returns a Data::Comment" do
      result = adapter.add_comment(repo: repo, number: issue_number, body: comment_body)

      expect(result).to be_a(Automation::Providers::Data::Comment)
      expect(result.body).to eq(comment_body)
    end
  end

  describe "#transition_state" do
    it "returns a Data::Issue" do
      result = adapter.transition_state(repo: repo, number: issue_number, state: :closed)

      expect(result).to be_a(Automation::Providers::Data::Issue)
    end
  end

  describe "expected provider failures" do
    it "translates them into WorkItemProvider::ProviderError" do
      stub_expected_provider_failure

      expect(&invoke_expected_provider_failure).to raise_error(
        Automation::Providers::WorkItemProvider::ProviderError,
        provider_failure_message
      )
    end
  end
end
