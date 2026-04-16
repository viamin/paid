# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::ReviewProvider do
  let(:unimplemented_class) do
    Class.new do
      include Automation::Providers::ReviewProvider
    end
  end

  let(:unimplemented) { unimplemented_class.new }

  describe "the interface contract" do
    it "declares the capability methods automation policy depends on" do
      expected_methods = %i[
        fetch_reviews
        fetch_review_threads
        fetch_review_requests
        fetch_pending_reviewers
        request_reviewers
        submit_review
        resolve_review_thread
      ]

      expect(described_class.instance_methods(false)).to include(*expected_methods)
    end

    it "raises NotImplementedError for each method when not overridden" do
      expect { unimplemented.fetch_reviews(repo: "x/y", pr_number: 1) }
        .to raise_error(NotImplementedError, /#fetch_reviews/)
      expect { unimplemented.fetch_review_threads(repo: "x/y", pr_number: 1) }
        .to raise_error(NotImplementedError, /#fetch_review_threads/)
      expect { unimplemented.fetch_review_requests(repo: "x/y", pr_number: 1) }
        .to raise_error(NotImplementedError, /#fetch_review_requests/)
      expect { unimplemented.fetch_pending_reviewers(repo: "x/y", pr_number: 1) }
        .to raise_error(NotImplementedError, /#fetch_pending_reviewers/)
      expect { unimplemented.request_reviewers(repo: "x/y", pr_number: 1, reviewers: []) }
        .to raise_error(NotImplementedError, /#request_reviewers/)
      expect { unimplemented.submit_review(repo: "x/y", pr_number: 1, body: "", event: :comment) }
        .to raise_error(NotImplementedError, /#submit_review/)
      expect { unimplemented.resolve_review_thread(repo: "x/y", pr_number: 1, thread_id: "t") }
        .to raise_error(NotImplementedError, /#resolve_review_thread/)
    end

    it "provides a ProviderError base class for implementations to extend" do
      expect(described_class::ProviderError).to be < StandardError
    end
  end

  describe "a conforming implementation" do
    let(:implementation_class) do
      Class.new do
        include Automation::Providers::ReviewProvider

        def fetch_reviews(repo:, pr_number:); []; end
        def fetch_review_threads(repo:, pr_number:); []; end

        def fetch_review_requests(repo:, pr_number:)
          Automation::Providers::Data::ReviewRequest.new(users: [], teams: [])
        end

        def fetch_pending_reviewers(repo:, pr_number:); []; end

        def request_reviewers(repo:, pr_number:, reviewers:)
          reviewers
        end

        def submit_review(repo:, pr_number:, body:, event:)
          Automation::Providers::Data::Review.new(
            id: 1, author_login: "bot", state: :commented, raw_state: "COMMENTED",
            body: body, submitted_at: Time.now, commit_sha: "abc"
          )
        end

        def resolve_review_thread(repo:, pr_number:, thread_id:); end
      end
    end

    it "can fulfill every interface method without raising" do
      impl = implementation_class.new

      expect(impl.fetch_reviews(repo: "x/y", pr_number: 1)).to eq([])
      expect(impl.fetch_review_threads(repo: "x/y", pr_number: 1)).to eq([])
      expect(impl.fetch_review_requests(repo: "x/y", pr_number: 1))
        .to be_a(Automation::Providers::Data::ReviewRequest)
      expect(impl.fetch_pending_reviewers(repo: "x/y", pr_number: 1)).to eq([])
      expect(impl.request_reviewers(repo: "x/y", pr_number: 1, reviewers: [ "a" ])).to eq([ "a" ])
      expect(impl.submit_review(repo: "x/y", pr_number: 1, body: "lgtm", event: :approve))
        .to be_a(Automation::Providers::Data::Review)
      expect { impl.resolve_review_thread(repo: "x/y", pr_number: 1, thread_id: "t") }.not_to raise_error
    end
  end
end
