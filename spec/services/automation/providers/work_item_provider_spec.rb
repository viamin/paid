# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::WorkItemProvider do
  let(:unimplemented_class) do
    Class.new do
      include Automation::Providers::WorkItemProvider
    end
  end

  let(:unimplemented) { unimplemented_class.new }

  describe "the interface contract" do
    it "declares the capability methods automation policy depends on" do
      expected_methods = %i[
        fetch_issue
        list_issues
        fetch_issue_comments
        fetch_issue_timeline
        create_issue
        add_labels
        remove_label
        add_comment
        transition_state
      ]

      expect(described_class.instance_methods(false)).to include(*expected_methods)
    end

    it "raises NotImplementedError for each method when not overridden" do
      expect { unimplemented.fetch_issue(repo: "x/y", number: 1) }
        .to raise_error(NotImplementedError, /#fetch_issue/)
      expect { unimplemented.list_issues(repo: "x/y") }
        .to raise_error(NotImplementedError, /#list_issues/)
      expect { unimplemented.fetch_issue_comments(repo: "x/y", number: 1) }
        .to raise_error(NotImplementedError, /#fetch_issue_comments/)
      expect { unimplemented.fetch_issue_timeline(repo: "x/y", number: 1) }
        .to raise_error(NotImplementedError, /#fetch_issue_timeline/)
      expect { unimplemented.create_issue(repo: "x/y", title: "t") }
        .to raise_error(NotImplementedError, /#create_issue/)
      expect { unimplemented.add_labels(repo: "x/y", number: 1, labels: []) }
        .to raise_error(NotImplementedError, /#add_labels/)
      expect { unimplemented.remove_label(repo: "x/y", number: 1, label: "a") }
        .to raise_error(NotImplementedError, /#remove_label/)
      expect { unimplemented.add_comment(repo: "x/y", number: 1, body: "") }
        .to raise_error(NotImplementedError, /#add_comment/)
      expect { unimplemented.transition_state(repo: "x/y", number: 1, state: :closed) }
        .to raise_error(NotImplementedError, /#transition_state/)
    end

    it "provides a ProviderError base class for implementations to extend" do
      expect(described_class::ProviderError).to be < StandardError
    end
  end

  describe "a conforming implementation" do
    let(:implementation_class) do
      Class.new do
        include Automation::Providers::WorkItemProvider

        def fetch_issue(repo:, number:)
          Automation::Providers::Data::Issue.new(
            number: number, title: "t", body: "",
            state: :open, raw_state: "open",
            author_login: "alice", assignee_logins: [], labels: [],
            dependencies: [], created_at: Time.now, updated_at: Time.now,
            closed_at: nil, url: nil, pull_request_number: nil
          )
        end

        def list_issues(repo:, state: :open, labels: nil, assignees: nil); []; end
        def fetch_issue_comments(repo:, number:); []; end
        def fetch_issue_timeline(repo:, number:); []; end

        def create_issue(repo:, title:, body: "", labels: [])
          fetch_issue(repo: repo, number: 1)
        end

        def add_labels(repo:, number:, labels:); end
        def remove_label(repo:, number:, label:); end

        def add_comment(repo:, number:, body:)
          Automation::Providers::Data::Comment.new(
            id: 1, author_login: nil, body: body,
            created_at: Time.now, updated_at: nil, url: nil
          )
        end

        def transition_state(repo:, number:, state:, reason: nil)
          fetch_issue(repo: repo, number: number)
        end
      end
    end

    it "can fulfill every interface method without raising" do
      impl = implementation_class.new

      expect(impl.fetch_issue(repo: "x/y", number: 1))
        .to be_a(Automation::Providers::Data::Issue)
      expect(impl.list_issues(repo: "x/y")).to eq([])
      expect(impl.fetch_issue_comments(repo: "x/y", number: 1)).to eq([])
      expect(impl.fetch_issue_timeline(repo: "x/y", number: 1)).to eq([])
      expect(impl.create_issue(repo: "x/y", title: "t"))
        .to be_a(Automation::Providers::Data::Issue)
      expect { impl.add_labels(repo: "x/y", number: 1, labels: [ "a" ]) }.not_to raise_error
      expect { impl.remove_label(repo: "x/y", number: 1, label: "a") }.not_to raise_error
      expect(impl.add_comment(repo: "x/y", number: 1, body: "hi"))
        .to be_a(Automation::Providers::Data::Comment)
      expect(impl.transition_state(repo: "x/y", number: 1, state: :closed))
        .to be_a(Automation::Providers::Data::Issue)
    end
  end
end
