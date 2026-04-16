# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::RepositoryProvider do
  # A minimal class that includes the interface without implementing any
  # method. Used to verify that every contract method raises
  # NotImplementedError by default — implementations MUST override them.
  let(:unimplemented_class) do
    Class.new do
      include Automation::Providers::RepositoryProvider
    end
  end

  let(:unimplemented) { unimplemented_class.new }

  describe "the interface contract" do
    it "declares the capability methods automation policy depends on" do
      expected_methods = %i[
        fetch_pull_request
        list_pull_requests
        fetch_pull_request_files
        fetch_check_runs
        add_labels
        remove_label
        add_comment
        mark_ready_for_review
        merge_pull_request
      ]

      expect(described_class.instance_methods(false)).to include(*expected_methods)
    end

    it "raises NotImplementedError for each method when not overridden" do
      expect { unimplemented.fetch_pull_request(repo: "x/y", number: 1) }
        .to raise_error(NotImplementedError, /#fetch_pull_request/)
      expect { unimplemented.list_pull_requests(repo: "x/y") }
        .to raise_error(NotImplementedError, /#list_pull_requests/)
      expect { unimplemented.fetch_pull_request_files(repo: "x/y", number: 1) }
        .to raise_error(NotImplementedError, /#fetch_pull_request_files/)
      expect { unimplemented.fetch_check_runs(repo: "x/y", ref: "main") }
        .to raise_error(NotImplementedError, /#fetch_check_runs/)
      expect { unimplemented.add_labels(repo: "x/y", number: 1, labels: []) }
        .to raise_error(NotImplementedError, /#add_labels/)
      expect { unimplemented.remove_label(repo: "x/y", number: 1, label: "a") }
        .to raise_error(NotImplementedError, /#remove_label/)
      expect { unimplemented.add_comment(repo: "x/y", number: 1, body: "") }
        .to raise_error(NotImplementedError, /#add_comment/)
      expect { unimplemented.mark_ready_for_review(repo: "x/y", number: 1) }
        .to raise_error(NotImplementedError, /#mark_ready_for_review/)
      expect { unimplemented.merge_pull_request(repo: "x/y", number: 1, method: :squash) }
        .to raise_error(NotImplementedError, /#merge_pull_request/)
    end

    it "provides a ProviderError base class for implementations to extend" do
      expect(described_class::ProviderError).to be < StandardError
    end
  end

  describe "a conforming implementation" do
    let(:implementation_class) do
      Class.new do
        include Automation::Providers::RepositoryProvider

        def fetch_pull_request(repo:, number:)
          Automation::Providers::Data::PullRequest.new(
            number: number, title: "t", body: "", state: :open,
            draft: false, merged: false, mergeable: true,
            head_sha: "abc", head_ref: "feature", base_ref: "main",
            author_login: "alice", labels: [], created_at: Time.now,
            updated_at: Time.now, merged_at: nil, url: nil, raw_state: nil
          )
        end

        def list_pull_requests(repo:, state: :open, head: nil, base: nil)
          []
        end

        def fetch_pull_request_files(repo:, number:)
          []
        end

        def fetch_check_runs(repo:, ref:)
          []
        end

        def add_labels(repo:, number:, labels:); end
        def remove_label(repo:, number:, label:); end

        def add_comment(repo:, number:, body:)
          Automation::Providers::Data::Comment.new(
            id: 1, author_login: "bot", body: body,
            created_at: Time.now, updated_at: nil, url: nil
          )
        end

        def mark_ready_for_review(repo:, number:); end

        def merge_pull_request(repo:, number:, method:, commit_title: nil, commit_message: nil)
          Automation::Providers::Data::MergeResult.new(merged: true, sha: "abc", message: "merged")
        end
      end
    end

    it "can fulfill every interface method without raising" do
      impl = implementation_class.new

      expect(impl.fetch_pull_request(repo: "x/y", number: 1))
        .to be_a(Automation::Providers::Data::PullRequest)
      expect(impl.list_pull_requests(repo: "x/y")).to eq([])
      expect(impl.fetch_pull_request_files(repo: "x/y", number: 1)).to eq([])
      expect(impl.fetch_check_runs(repo: "x/y", ref: "main")).to eq([])
      expect { impl.add_labels(repo: "x/y", number: 1, labels: [ "a" ]) }.not_to raise_error
      expect { impl.remove_label(repo: "x/y", number: 1, label: "a") }.not_to raise_error
      expect(impl.add_comment(repo: "x/y", number: 1, body: "hi"))
        .to be_a(Automation::Providers::Data::Comment)
      expect { impl.mark_ready_for_review(repo: "x/y", number: 1) }.not_to raise_error
      expect(impl.merge_pull_request(repo: "x/y", number: 1, method: :squash))
        .to be_a(Automation::Providers::Data::MergeResult)
    end
  end
end
