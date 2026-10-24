# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-002
RSpec.describe Tools::PublishHeldIssue do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:feature) { create(:feature_intent, :confidence_driven, project: project) }
  let(:parent) { create(:issue, project: project) }
  let(:prerequisite) { create(:issue, project: project) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }
  let(:github_client) { instance_double(GithubClient) }
  let(:created_bodies) { {} }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue) do |_repo, title:, body:, labels:|
      remote = remote_for(number: 4242, title: title, body: body, labels: labels)
      created_bodies[remote.number] = body
      remote
    end
    allow(github_client).to receive(:issue) do |_repo, number|
      remote_for(number: number, title: "Coherent task", body: created_bodies.fetch(number, "missing"), labels: [ "planning" ])
    end
    allow(github_client).to receive(:search_issues) { Struct.new(:items).new([]) }
  end

  def remote_for(number:, title:, body:, labels:)
    Struct.new(:id, :number, :title, :body, :state, :labels, :user, :html_url, :created_at, :updated_at,
      keyword_init: true).new(
        id: 990_000 + number,
        number: number,
        title: title,
        body: body,
        state: "open",
        labels: Array(labels).map { |name| Struct.new(:name).new(name) },
        user: Struct.new(:login).new("paid-agent"),
        html_url: "https://github.com/#{project.full_name}/issues/#{number}",
        created_at: Time.current,
        updated_at: Time.current
      )
  end

  def call_tool(**overrides)
    tool.call(
      feature_intent_id: feature.id,
      title: "Coherent task",
      body: "Coherent purpose and scope.",
      parent_issue_number: parent.github_number,
      depends_on_issue_numbers: [ prerequisite.github_number ],
      speculative_alternatives: [ { "title" => "Alternative A", "summary" => "Still exploring." } ],
      confirmed: true,
      **overrides
    )
  end

  it "requires confirmation before publishing" do
    expect { call_tool(confirmed: false) }.to raise_error(ArgumentError, /Confirmation required/)
    expect(github_client).not_to have_received(:create_issue)
  end

  it "publishes a planning-held issue and returns its identity" do
    result = call_tool

    expect(result[:number]).to eq(4242)
    expect(result[:url]).to eq("https://github.com/#{project.full_name}/issues/4242")
    expect(result[:feature_intent_issue_id]).to be_positive
    expect(result[:reused]).to be(false)

    issue = project.issues.find_by(github_number: 4242)
    expect(issue.labels).to include("planning")
    expect(issue.parent_issue_id).to eq(parent.id)
    expect(IssueDependency.where(issue: issue, depends_on_issue: prerequisite)).to exist
    expect(feature.feature_intent_issues.find_by(issue: issue).release_state).to eq("held")
    expect(feature.reload.speculative_alternatives).to include(hash_including("title" => "Alternative A"))
  end

  it "denies users who cannot manage the project's issues" do
    viewer = create(:user, :viewer, account:)

    expect do
      described_class.new(user: viewer, session:).call(feature_intent_id: feature.id, title: "Task", confirmed: true)
    end.to raise_error(Pundit::NotAuthorizedError)
  end

  it "refuses approval-gated features" do
    approval_gated = create(:feature_intent, project: project)

    expect { call_tool(feature_intent_id: approval_gated.id) }.to raise_error(ArgumentError, /confidence-driven/)
  end

  it "rejects unknown dependency issue numbers" do
    expect { call_tool(depends_on_issue_numbers: [ 999_999 ]) }
      .to raise_error(ArgumentError, /Unknown dependency issue number 999999/)
  end

  it "rejects facets outside the feature" do
    other_facet = create(:feature_intent_facet, feature_intent: create(:feature_intent, :confidence_driven, project: project))

    expect { call_tool(facet_prerequisites: [ { "facet_id" => other_facet.id } ]) }
      .to raise_error(ArgumentError, /does not belong to feature/)
  end
end
