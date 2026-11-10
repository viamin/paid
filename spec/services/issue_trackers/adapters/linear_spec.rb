# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueTrackers::Adapters::Linear do
  let(:account) { create(:account) }
  let(:credential) { create(:integration_credential, account:, service_key: "linear", secret: "lin_api_#{'a' * 40}") }
  let(:configuration) { create(:tracker_configuration, :linear, configurable: account, integration_credential: credential) }
  let(:adapter) { described_class.new(configuration) }
  let(:endpoint) { "https://api.linear.app/graphql" }

  def stub_graphql(data, status: 200, headers: {})
    stub_request(:post, endpoint).to_return(status:, headers:, body: JSON.generate(data))
  end

  it "validates the account connection using its configured credential" do
    # @spec UNIFIED-WORK-ITEMS-002
    request = stub_graphql({ data: { viewer: { id: "user-1" } } })

    expect(adapter.validate_connection!).to be(true)
    expect(request).to have_been_requested.with(headers: { "Authorization" => credential.secret })
  end

  it "lists all ticket pages and retains provider payloads" do
    # @spec UNIFIED-WORK-ITEMS-003
    first_page = { data: { issues: { nodes: [ { id: "id-1", identifier: "ENG-1", title: "First",
      description: "Body", url: "https://linear.app/acme/issue/ENG-1", state: { name: "Todo" },
      labels: { nodes: [] } } ], pageInfo: { hasNextPage: true, endCursor: "next" } } } }
    second_page = { data: { issues: { nodes: [ { id: "id-2", identifier: "ENG-2", title: "Second",
      state: { name: "Done" }, labels: { nodes: [] } } ], pageInfo: { hasNextPage: false, endCursor: "end" } } } }
    stub_request(:post, endpoint).to_return(body: JSON.generate(first_page), status: 200)
      .then.to_return(body: JSON.generate(second_page), status: 200)

    issues = adapter.list_issues

    expect(issues.map(&:external_id)).to eq(%w[id-1 id-2])
    expect(issues.first.metadata.fetch("identifier")).to eq("ENG-1")
    expect(issues.first.metadata.fetch("raw_payload").fetch("title")).to eq("First")
  end

  it "reports GraphQL errors even when HTTP succeeds" do
    # @spec UNIFIED-WORK-ITEMS-002
    stub_graphql({ errors: [ { message: "Invalid key", extensions: { code: "AUTHENTICATION_ERROR" } } ] })

    expect { adapter.validate_connection! }.to raise_error(IssueTrackers::Adapters::Linear::AuthenticationError)
  end

  it "rejects a missing credential before making a request" do
    # @spec UNIFIED-WORK-ITEMS-002
    configuration.update!(integration_credential: nil)

    expect { adapter.validate_connection! }.to raise_error(IssueTrackers::Adapters::Linear::AuthenticationError)
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  it "updates a ticket using a Linear workflow-state ID" do
    # @spec UNIFIED-WORK-ITEMS-003
    request = stub_graphql({ data: { issueUpdate: { success: true, issue: { id: "issue-1" } } } })

    expect(adapter.update_status(external_id: "issue-1", status: "state-2")).to eq("issue-1")
    expect(request).to have_been_requested.with { |http_request|
      JSON.parse(http_request.body).dig("variables", "input", "stateId") == "state-2"
    }
  end

  it "reports rate limits with retry information" do
    # @spec UNIFIED-WORK-ITEMS-002
    stub_graphql({ errors: [ { message: "Slow down", extensions: { code: "RATELIMITED" } } ] },
      status: 429, headers: { "Retry-After" => "12" })

    expect { adapter.list_issues }.to raise_error(IssueTrackers::Adapters::Linear::RateLimitedError) { |error|
      expect(error.retry_after).to eq(12)
    }
  end

  it "classifies an HTTP authentication failure even with a non-JSON body" do
    # @spec UNIFIED-WORK-ITEMS-002
    stub_request(:post, endpoint).to_return(status: 401, body: "Unauthorized")

    expect { adapter.validate_connection! }.to raise_error(IssueTrackers::Adapters::Linear::AuthenticationError)
  end

  it "creates a comment and a pull request attachment" do
    # @spec UNIFIED-WORK-ITEMS-003
    stub_request(:post, endpoint).to_return(
      { status: 200, body: JSON.generate(data: { commentCreate: { success: true, comment: { id: "comment-1" } } }) },
      { status: 200, body: JSON.generate(data: { attachmentCreate: { success: true, attachment: { id: "attachment-1" } } }) }
    )

    expect(adapter.add_comment(external_id: "issue-1", body: "Update")).to eq("comment-1")
    expect(adapter.link_pr(external_id: "issue-1", pr_url: "https://github.com/acme/app/pull/3",
      pr_title: "Fix")).to eq("attachment-1")
  end
end
