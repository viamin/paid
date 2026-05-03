# frozen_string_literal: true

# Shared examples verifying that a concrete ReviewProvider
# implementation satisfies the interface contract.
#
# Expected `let` bindings:
#
#   adapter     — an instance of the implementation class
#   repo        — a String repo identifier
#   pr_number   — an Integer PR number whose review queries succeed
#
# The adapter's underlying client should be stubbed to return valid
# data for the given repo/pr_number combination.
RSpec.shared_examples "a ReviewProvider implementation" do
  it "includes the ReviewProvider module" do
    expect(adapter.class.ancestors).to include(Automation::Providers::ReviewProvider)
  end

  describe "#fetch_reviews" do
    it "returns an Array of Data::Review" do
      result = adapter.fetch_reviews(repo: repo, pr_number: pr_number)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::Review))
      result.each { |r| expect(Automation::Providers::Data::Review::STATES).to include(r.state) }
    end

    it "downcases author_login on returned reviews" do
      result = adapter.fetch_reviews(repo: repo, pr_number: pr_number)

      result.each { |r| expect(r.author_login).to eq(r.author_login.downcase) unless r.author_login.nil? }
    end
  end

  describe "#fetch_review_threads" do
    it "returns an Array of Data::ReviewThread" do
      result = adapter.fetch_review_threads(repo: repo, pr_number: pr_number)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(Automation::Providers::Data::ReviewThread))
    end
  end

  describe "#fetch_review_requests" do
    it "returns a Data::ReviewRequest" do
      result = adapter.fetch_review_requests(repo: repo, pr_number: pr_number)

      expect(result).to be_a(Automation::Providers::Data::ReviewRequest)
      expect(result.users).to be_an(Array)
      expect(result.teams).to be_an(Array)
    end
  end

  describe "#fetch_pending_reviewers" do
    it "returns an Array of downcased Strings" do
      result = adapter.fetch_pending_reviewers(repo: repo, pr_number: pr_number)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(String))
      expect(result).to all(satisfy("be downcased") { |l| l == l.downcase })
    end
  end

  describe "#request_reviewers" do
    it "returns an Array of Strings (the newly-requested subset)" do
      result = adapter.request_reviewers(repo: repo, pr_number: pr_number, reviewers: [ "alice" ])

      expect(result).to be_an(Array)
      expect(result).to all(be_a(String))
    end
  end

  describe "#submit_review" do
    it "returns a Data::Review" do
      result = adapter.submit_review(
        repo: repo, pr_number: pr_number, body: "lgtm", event: :approve
      )

      expect(result).to be_a(Automation::Providers::Data::Review)
      expect(Automation::Providers::Data::Review::STATES).to include(result.state)
    end
  end

  describe "#resolve_review_thread" do
    it "does not raise (idempotent)" do
      expect { adapter.resolve_review_thread(repo: repo, pr_number: pr_number, thread_id: "t1") }
        .not_to raise_error
    end
  end
end
