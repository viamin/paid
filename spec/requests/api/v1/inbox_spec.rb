# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile inbox API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "mobile") }
  let(:plaintext) { "paid_pat_#{SecureRandom.urlsafe_base64(32)}" }
  let(:token) do
    PersonalAccessToken.create!(
      user:,
      account:,
      name: "Mobile",
      scopes: %w[inbox chat],
      token_digest: PersonalAccessToken.digest(plaintext)
    )
  end
  let(:headers) { token; { "Authorization" => "Bearer #{plaintext}" } }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?" ]) }

  # @spec MOBILE-API-006 MOBILE-API-010
  it "lists filtered entries and conditionally returns not modified" do
    issue
    get "/api/v1/inbox", params: { kind: "clarifying_questions", project_id: project.id }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entries").first).to include(
      "id" => "clarifying_questions:#{issue.id}", "kind" => "clarifying_questions",
      "project" => { "id" => project.id, "owner" => "acme", "repo" => "mobile", "name" => "acme/mobile" }
    )
    expect(response.headers["Cache-Control"]).to include("private", "max-age=0")

    get "/api/v1/inbox", params: { kind: "clarifying_questions", project_id: project.id },
      headers: headers.merge("If-None-Match" => response.headers.fetch("ETag"))

    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
  end

  # @spec MOBILE-API-006 MOBILE-API-010
  it "paginates the inbox before serializing entries" do
    issues = create_list(:issue, 3, :needs_input, project:, needs_input_questions: [ "What should happen?" ])

    get "/api/v1/inbox", params: { kind: "clarifying_questions", limit: 2 }, headers: headers

    expect(response).to have_http_status(:ok)
    first_page = response.parsed_body
    expect(first_page.fetch("entries").size).to eq(2)
    expect(first_page.fetch("next_cursor")).to eq(first_page.fetch("entries").last.fetch("id"))

    get "/api/v1/inbox", params: { kind: "clarifying_questions", limit: 2, cursor: first_page.fetch("next_cursor") }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entries").map { |entry| entry.fetch("id") }).to eq(
      issues.map { |issue| "clarifying_questions:#{issue.id}" } - first_page.fetch("entries").map { |entry| entry.fetch("id") }
    )
    expect(response.parsed_body).not_to have_key("next_cursor")
  end

  # @spec MOBILE-API-007 MOBILE-API-010
  it "returns a cached badge count with a conditional response" do
    issue

    get "/api/v1/inbox/count", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("count" => 1)
    etag = response.headers.fetch("ETag")

    get "/api/v1/inbox/count", headers: headers.merge("If-None-Match" => etag)

    expect(response).to have_http_status(:not_modified)
  end

  # @spec MOBILE-API-008 MOBILE-API-009
  it "re-resolves an entry and opens its native chat" do
    issue
    entry_id = "clarifying_questions:#{issue.id}"

    get "/api/v1/inbox/entries/#{entry_id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entry")).to include("id" => entry_id)

    post "/api/v1/inbox/entries/#{entry_id}/chat", headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("chat_session_id")).to be_present
  end

  # @spec MOBILE-API-009
  it "forbids opening chat for a token scoped to inbox only" do
    issue
    entry_id = "clarifying_questions:#{issue.id}"
    inbox_only_plaintext = "paid_pat_#{SecureRandom.urlsafe_base64(32)}"
    PersonalAccessToken.create!(
      user:,
      account:,
      name: "Inbox-only",
      scopes: %w[inbox],
      token_digest: PersonalAccessToken.digest(inbox_only_plaintext)
    )

    post "/api/v1/inbox/entries/#{entry_id}/chat",
      headers: { "Authorization" => "Bearer #{inbox_only_plaintext}" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("forbidden")
  end

  # @spec MOBILE-API-008
  it "does not expose entries outside the bearer tenant" do
    foreign_account = create(:account)
    foreign_project = create(:project, account: foreign_account, created_by: create(:user, account: foreign_account))
    foreign_issue = create(:issue, :needs_input, project: foreign_project, needs_input_questions: [ "Private" ])

    get "/api/v1/inbox/entries/clarifying_questions:#{foreign_issue.id}", headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("not_found")
  end
end
