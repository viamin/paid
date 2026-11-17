# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Layered verification review packages API" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:plaintext) { PersonalAccessToken.generate_plaintext }
  let(:headers) { { "Authorization" => "Bearer #{plaintext}", "Content-Type" => "application/json" } }
  let(:obligation) { create(:layered_verification_obligation, project:, external_revision: "review-sha") }
  let(:audit) do
    run = create(:agent_run, project:, goal: "layered_verification_audit", status: "completed")
    create(:layered_verification_check_result, obligation:, agent_run: run,
      input_revision: { "target_revision" => "a" * 40 })
    run.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "a" * 40,
      "plan" => {}, "coverage" => {}
    } })
    run
  end
  let!(:package) { LayeredVerification::ReviewPackages::Capture.call(agent_run: audit) }

  before do
    create(:personal_access_token, user:, account:, name: "Review packages", scopes: [ "inbox" ], plaintext:)
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  # @spec LAYERED-VERIFY-023
  it "inspects bounded history and detail through the authenticated API" do
    get "/api/v1/projects/#{project.id}/layered_verification_review_packages", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("review_packages").first).to include("id" => package.id)

    get "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("id" => package.id, "bound_inputs" => include("obligations"))
  end

  # @spec LAYERED-VERIFY-023
  it "paginates package history with a bounded discoverable cursor" do
    lineage = Array.new(100) do |index|
      create(:layered_verification_review_package, project:, agent_run: audit,
        revision_number: index + 2)
    end

    get "/api/v1/projects/#{project.id}/layered_verification_review_packages", headers: headers
    first_page = response.parsed_body
    expect(first_page.fetch("review_packages").size).to eq(50)
    expect(first_page.fetch("next_cursor")).to eq(first_page.fetch("review_packages").last.fetch("id"))

    get "/api/v1/projects/#{project.id}/layered_verification_review_packages",
      params: { limit: 100, cursor: first_page.fetch("next_cursor") }, headers: headers
    expect(response.parsed_body.fetch("review_packages").map { |item| item.fetch("id") })
      .to eq(lineage.drop(49).map(&:id))
    expect(response.parsed_body).not_to have_key("next_cursor")
  end

  # @spec LAYERED-VERIFY-023
  it "paginates package detail lineage with a bounded discoverable cursor" do
    lineage = Array.new(100) do |index|
      create(:layered_verification_review_package, project:, agent_run: audit,
        revision_number: index + 2)
    end

    get "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}", headers: headers
    detail = response.parsed_body
    expect(detail.fetch("lineage").size).to eq(50)
    expect(detail.fetch("lineage_next_cursor")).to eq(lineage[48].id)

    get "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}",
      params: { lineage_limit: 100, lineage_cursor: detail.fetch("lineage_next_cursor") }, headers: headers
    expect(response.parsed_body.fetch("lineage").map { |item| item.fetch("id") })
      .to eq(lineage.drop(49).map(&:id))
    expect(response.parsed_body).not_to have_key("lineage_next_cursor")
  end

  # @spec LAYERED-VERIFY-023
  it "rejects package and lineage limits outside the documented range" do
    expect {
      get "/api/v1/projects/#{project.id}/layered_verification_review_packages",
        params: { limit: 101 }, headers: headers
    }.to raise_error(Committee::InvalidRequest)

    expect {
      get "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}",
        params: { lineage_limit: 0 }, headers: headers
    }.to raise_error(Committee::InvalidRequest)
  end

  # @spec LAYERED-VERIFY-023
  it "records a confirmed API approval with server-supplied provenance and no repair or release" do
    supplied_actor = create(:user, account:)

    expect {
      post "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}/approve",
        params: { confirmed: true, approved_by_id: supplied_actor.id }.to_json, headers: headers
    }.to raise_error(Committee::InvalidRequest)

    expect {
      post "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}/approve",
        params: { note: "Reviewed the retry behavior.", confirmed: true }.to_json, headers: headers
    }.not_to change(AgentRun, :count)

    expect(response).to have_http_status(:created)
    approval = package.reload.approvals.sole
    expect(approval).to have_attributes(approved_by: user)
    expect(approval.provenance).to include("surface" => "api", "note" => "Reviewed the retry behavior.")
    expect(AgentRun.where(project:, goal: "layered_verification_repair")).to be_empty
  end

  # @spec LAYERED-VERIFY-012 LAYERED-VERIFY-023
  it "returns structured disabled, stale, and cross-project errors without creating an approval" do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    get "/api/v1/projects/#{project.id}/layered_verification_review_packages", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("layered_verification_unavailable")

    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    obligation.update!(external_revision: "new-review-sha")

    post "/api/v1/projects/#{project.id}/layered_verification_review_packages/#{package.id}/approve",
      params: { confirmed: true }.to_json, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("stale_review_package")
    expect(package.reload.approvals).to be_empty

    other_project = create(:project)
    get "/api/v1/projects/#{other_project.id}/layered_verification_review_packages/#{package.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
