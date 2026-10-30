# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mobile inbox API" do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_cache
  end

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

    travel_to(Time.zone.local(2026, 10, 12, 12, 0, 0)) do
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
  end

  # @spec AUTO-PICK-QUEUE-015 MOBILE-API-006
  it "does not serialize dependency cycles that cross another owner's project" do
    other_user = create(:user, account:)
    hidden_project = create(:project, account:, created_by: other_user)
    visible_issue = create(:issue, project:, github_state: "open")
    hidden_issue = create(:issue, project: hidden_project, github_state: "open")
    create(:issue_dependency, issue: visible_issue, depends_on_issue: hidden_issue)
    create_legacy_issue_dependency(issue: hidden_issue, depends_on_issue: visible_issue)

    get "/api/v1/inbox", params: { kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entries")).to be_empty
  end

  # @spec AUTO-PICK-QUEUE-015 MOBILE-API-006
  it "serializes an authorized dependency cycle and resolves its fingerprint entry ID" do
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    declaration_url = "https://github.com/acme/mobile/issues/1#issuecomment-9"
    create(:issue_dependency, issue: first, depends_on_issue: second,
      declaration_source: "issue_comment", declaration_url: declaration_url)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)

    get "/api/v1/inbox", params: { kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND }, headers: headers

    entry = response.parsed_body.fetch("entries").sole
    expect(entry.fetch("cycle_path").map { |node| node.fetch("number") }).to include(first.github_number, second.github_number)
    expect(entry.fetch("cycle_edges")).to include(
      a_hash_including("declaration_source" => "issue_comment", "declaration_url" => declaration_url)
    )

    get "/api/v1/inbox/entries/#{entry.fetch("id")}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("entry", "id")).to eq(entry.fetch("id"))
  end

  # @spec AUTO-PICK-QUEUE-019 MOBILE-API-006
  it "keeps a prior analysis visible and marks it stale after the cycle edges change" do
    issues = Array.new(3) { create(:issue, project:, github_state: "open") }
    create_legacy_issue_dependency(issue: issues[0], depends_on_issue: issues[1])
    create_legacy_issue_dependency(issue: issues[1], depends_on_issue: issues[2])
    create_legacy_issue_dependency(issue: issues[2], depends_on_issue: issues[0])
    cycle = Issues::DependencyCycles.call(account:).sole
    run = create(:agent_run, :completed, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => { "fingerprint" => cycle.fingerprint,
        "occurrence" => cycle.occurrence, "graph_revision" => cycle.graph_revision } },
      verification_result: { CycleAnalyses::RESULT_KEY => { "recommendation" => "Review all declarations." } })
    create_legacy_issue_dependency(issue: issues[0], depends_on_issue: issues[2])
    current_cycle = Issues::DependencyCycles.call(account:).sole

    get "/api/v1/inbox/entries/#{current_cycle.id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("entry", "analysis_run")).to include(
      "id" => run.id, "stale" => true, "recommendation" => "Review all declarations."
    )
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
    stub_github_comments
    entry_id = "clarifying_questions:#{issue.id}"

    get "/api/v1/inbox/entries/#{entry_id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entry")).to include("id" => entry_id)

    post "/api/v1/inbox/entries/#{entry_id}/chat", headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("chat_session_id")).to be_present
  end

  # @spec OPERATOR-INBOX-022 MOBILE-API-008
  it "paginates action history with dedicated show parameters" do
    issue
    subject_key = "issue:#{project.id}:#{issue.github_number}"
    21.times do |index|
      create(:inbox_history_event, account:, project:, subject_key:,
        occurred_at: index.minutes.ago, metadata: { action: "Event #{index}" })
    end
    entry_id = "clarifying_questions:#{issue.id}"

    get "/api/v1/inbox/entries/#{entry_id}", params: { history_limit: 10 }, headers: headers
    first_page = response.parsed_body.fetch("entry")
    get "/api/v1/inbox/entries/#{entry_id}",
      params: { history_limit: 10, history_cursor: first_page.fetch("history_next_cursor") }, headers: headers
    second_page = response.parsed_body.fetch("entry")

    expect(first_page.fetch("history").size).to eq(10)
    expect(second_page.fetch("history").size).to eq(10)
    expect(first_page.fetch("history").pluck("id") & second_page.fetch("history").pluck("id")).to be_empty
  end

  # @spec OPERATOR-INBOX-022 MOBILE-API-008
  it "treats a run cursor as invalid for a feature entry" do
    feature_intent = create(:feature_intent, :ready_for_approval, project:)

    get "/api/v1/inbox/entries/feature_decision:#{feature_intent.id}",
      params: { history_cursor: "run-start:1" }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("entry")).to include("history" => [], "history_incomplete" => false)
  end

  it "returns not found instead of opening a chat for an unavailable entry" do # @spec MOBILE-API-009
    post "/api/v1/inbox/entries/clarifying_questions:999999/chat", headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("not_found")
  end

  # @spec QUESTION-EXPLORATION-012 QUESTION-EXPLORATION-018
  it "opens the same linked conversation the Inbox detail pane opens, attributed to the bearer" do
    issue
    stub_github_comments
    entry_id = "clarifying_questions:#{issue.id}"
    html_chat = ClarifyingQuestions::OpenChat.call(issue: issue, user: user)

    post "/api/v1/inbox/entries/#{entry_id}/chat", headers: headers

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("chat_session_id")).to eq(html_chat.id)
    chat = ChatSession.find(html_chat.id)
    expect(chat.clarifying_question_issue).to eq(issue)
    expect(chat.created_by).to eq(user)
  end

  # @spec QUESTION-EXPLORATION-018
  it "opens the feature conversation for a feature issue on an exploration-enabled project" do
    project.update!(question_exploration_enabled: true)
    stub_github_comments
    feature = create(:feature_intent, project: project)
    create(:feature_intent_issue, feature_intent: feature, issue: issue)
    entry_id = "clarifying_questions:#{issue.id}"

    post "/api/v1/inbox/entries/#{entry_id}/chat", headers: headers

    expect(response).to have_http_status(:created)
    chat = ChatSession.find(response.parsed_body.fetch("chat_session_id"))
    expect(chat.feature_intent).to eq(feature)
    expect(chat.metadata["exploration_focus"]).to include("issue_id" => issue.id)
  end

  def stub_github_comments
    github_client = instance_double(GithubClient)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:issue_comments).and_return([])
  end

  # @spec MOBILE-API-008 MOBILE-API-018
  it "accepts a percent-encoded colon in an inbox entry ID" do
    issue
    entry_id = "clarifying_questions%3A#{issue.id}"

    get "/api/v1/inbox/entries/#{entry_id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("entry", "id")).to eq("clarifying_questions:#{issue.id}")
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

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records a current-revision reopen decision through the bearer Inbox surface" do
    reopen_issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))

    expect {
      post "/api/v1/inbox/entries/manual_review:#{reopen_issue.id}/resolve_reopen_review", params: {
        revision: reopen_issue.github_updated_at.iso8601,
        reason: "The reopened scope still needs current validation."
      }.to_json, headers: headers.merge("Content-Type" => "application/json")
    }.not_to change(AgentRun, :count)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("issue_id" => reopen_issue.id, "status" => "new")
    expect(reopen_issue.reload.paid_state).to eq("new")
    expect(AccountActivityEvent.last).to have_attributes(actor: user, subject: reopen_issue)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "keeps the reopen hold when the bearer submits a stale revision" do
    reopen_issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))

    post "/api/v1/inbox/entries/manual_review:#{reopen_issue.id}/resolve_reopen_review", params: {
      revision: "stale", reason: "The reopened scope still needs current validation."
    }.to_json, headers: headers.merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "message")).to include("changed after this review")
    expect(reopen_issue.reload).to be_reopen_review_pending
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "does not disclose or resolve a reopen decision without permission to run agents" do
    reopen_issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))
    viewer = create(:user, :viewer, account:)
    create(:project_membership, :viewer, user: viewer, project: project)
    viewer_plaintext = "paid_pat_#{SecureRandom.urlsafe_base64(32)}"
    PersonalAccessToken.create!(
      user: viewer, account:, name: "Viewer", scopes: %w[inbox],
      token_digest: PersonalAccessToken.digest(viewer_plaintext)
    )

    post "/api/v1/inbox/entries/manual_review:#{reopen_issue.id}/resolve_reopen_review", params: {
      revision: reopen_issue.github_updated_at.iso8601, reason: "The reopened scope still needs current validation."
    }.to_json, headers: { "Authorization" => "Bearer #{viewer_plaintext}", "Content-Type" => "application/json" }

    expect(response).to have_http_status(:not_found)
    expect(reopen_issue.reload).to be_reopen_review_pending
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

  # @spec FEATURE-APPROVAL-020
  it "rejects a cancellation without the required structured reason" do
    feature_intent = create(:feature_intent, project:, status: "discovering", criteria_clarity_state: "pending")

    expect {
      post "/api/v1/feature_intents/#{feature_intent.id}/cancel", params: {}.to_json,
        headers: headers.merge("Content-Type" => "application/json")
    }.to raise_error(Committee::InvalidRequest, /cancellation_reason/)

    expect(feature_intent.reload.status).to eq("discovering")
  end

  # @spec FEATURE-APPROVAL-020
  it "rejects a cancellation with a non-http(s) replacement reference" do
    feature_intent = create(:feature_intent, project:, status: "discovering", criteria_clarity_state: "pending")

    post "/api/v1/feature_intents/#{feature_intent.id}/cancel", params: {
      cancellation_reason: "already_handled",
      replacement_reference: "javascript:alert(1)"
    }.to_json, headers: headers.merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "message")).to eq("Replacement reference must be an http(s) URL")
    expect(feature_intent.reload.status).to eq("discovering")
  end

  # @spec INBOX-PHASE-RELEVANCE-002 @spec INBOX-PHASE-RELEVANCE-003
  # @spec INBOX-PHASE-RELEVANCE-006 @spec INBOX-PHASE-RELEVANCE-009
  describe "phase relevance and personal removal" do
    before do
      allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
      FeatureFlags.enable!(:automation_phases, project: project)
      project.update!(
        Automation::PhaseSettings::SETTINGS_KEY => {
          Automation::PhaseSettings::PHASES_KEY => { "issue_preparation" => false },
          Automation::PhaseSettings::RELEASE_KEY => false,
          Automation::PhaseSettings::DEPLOYMENT_KEY => false
        }
      )
    end

    it "keeps a request held by a disabled phase out of the default list and in the disabled view" do
      issue

      get "/api/v1/inbox", headers: headers
      expect(response.parsed_body.fetch("entries")).to be_empty

      get "/api/v1/inbox", params: { scope: "disabled_phases" }, headers: headers
      expect(response.parsed_body.fetch("entries").map { |entry| entry["id"] })
        .to eq([ "clarifying_questions:#{issue.id}" ])
    end

    it "removes a request for the caller and exposes the Removed view and restore" do
      issue

      post "/api/v1/inbox/entries/clarifying_questions:#{issue.id}/remove", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("removed" => true)

      get "/api/v1/inbox", headers: headers
      expect(response.parsed_body.fetch("entries")).to be_empty

      get "/api/v1/inbox", params: { scope: "removed" }, headers: headers
      expect(response.parsed_body.fetch("entries").size).to eq(1)

      post "/api/v1/inbox/entries/clarifying_questions:#{issue.id}/restore", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "agrees with the count endpoint about personally removed items" do
      issue

      post "/api/v1/inbox/entries/clarifying_questions:#{issue.id}/remove", headers: headers
      get "/api/v1/inbox/count", headers: headers

      expect(response.parsed_body.fetch("count")).to eq(0)
    end

    it "still allows direct inspection of a removed entry" do
      issue

      post "/api/v1/inbox/entries/clarifying_questions:#{issue.id}/remove", headers: headers
      get "/api/v1/inbox/entries/clarifying_questions:#{issue.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("entry", "id")).to eq("clarifying_questions:#{issue.id}")
    end
  end
end
