# frozen_string_literal: true

require "rails_helper"

# Fake for the GitHub boundary only: records creates, serves read-backs,
# and can simulate an interrupted local sync via searchable remote items.
class PublishHeldIssueFakeClient
  attr_reader :created_issues, :remote_items
  attr_accessor :read_back_body_override, :read_back_labels_override

  def initialize(planning_label:)
    @planning_label = planning_label
    @created_issues = []
    @remote_items = []
    @read_back_body_override = nil
    @read_back_labels_override = nil
    @next_number = 4242
  end

  def create_issue(repo, title:, body:, labels:)
    @next_number += 1
    number = @next_number
    @created_issues << { repo: repo, title: title, body: body, labels: labels, number: number }
    remote_issue(number: number, title: title, body: body, labels: labels)
  end

  def issue(_repo, number)
    remote = @remote_items.reverse.find { |candidate| candidate.number == number }
    return read_back(remote) if remote

    created = @created_issues.reverse.find { |entry| entry[:number] == number }
    return remote_issue(number: 4242, body: "missing") unless created

    remote_issue(
      number: number,
      title: created[:title],
      body: read_back_body_override || created[:body],
      labels: read_back_labels_override || [ @planning_label ]
    )
  end

  def read_back(remote)
    remote_issue(
      number: remote.number,
      title: remote.title,
      body: read_back_body_override || remote.body,
      labels: read_back_labels_override || remote.labels.map(&:name)
    )
  end

  def search_issues(_query, per_page: 100)
    Struct.new(:items).new(@remote_items.take(per_page))
  end

  def remote_issue(number:, body:, title: "Coherent task", labels: [ @planning_label ])
    Struct.new(
      :id, :number, :title, :body, :state, :labels, :user, :html_url, :created_at, :updated_at, :pull_request,
      keyword_init: true
    ).new(
      id: 990_000 + number,
      number: number,
      title: title,
      body: body,
      state: "open",
      labels: Array(labels).map { |name| Struct.new(:name).new(name) },
      user: Struct.new(:login).new("paid-agent"),
      html_url: "https://github.com/example/repo/issues/#{number}",
      created_at: Time.current,
      updated_at: Time.current,
      pull_request: nil
    )
  end
end

# @spec CONFIDENCE-DELIVERY-002
RSpec.describe FeatureIntents::PublishHeldIssue do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, :confidence_driven, project: project) }
  let(:parent) { create(:issue, project: project) }
  let(:prerequisite) { create(:issue, project: project) }
  let(:client) { PublishHeldIssueFakeClient.new(planning_label: FeatureIntents::ReleaseIssue::PLANNING_LABEL) }

  def publish(**overrides)
    described_class.call(
      feature_intent: feature,
      title: "Coherent task",
      body: "Coherent purpose and scope that is not ready to run.",
      parent_issue: parent,
      dependencies: [ prerequisite ],
      speculative_alternatives: [ { "title" => "Alternative A", "summary" => "Still exploring this shape." } ],
      client: client,
      **overrides
    )
  end

  it "publishes coherent work as a planning-held GitHub issue with explicit dependency text" do
    publish

    expect(client.created_issues.length).to eq(1)
    created = client.created_issues.first
    expect(created[:repo]).to eq(project.full_name)
    expect(created[:title]).to eq("Coherent task")
    expect(created[:labels]).to eq([ "planning" ])
    expect(created[:body]).to include("Sub-issue of ##{parent.github_number}")
    expect(created[:body]).to include("## Dependencies")
    expect(created[:body]).to include("- Depends on ##{prerequisite.github_number}")
    expect(created[:body]).to include("<!-- paid:planning-held:#{feature.id}:")
  end

  it "links the published issue to its feature, parent, and prerequisites" do
    create(:feature_intent_issue, feature_intent: feature, issue: prerequisite)
    result = publish

    issue = result.issue
    expect(issue.reload).to have_attributes(
      parent_issue_id: parent.id,
      github_number: client.created_issues.first[:number]
    )
    expect(issue.labels).to include("planning")
    expect(IssueDependency.where(issue: issue, depends_on_issue: prerequisite)).to exist

    link = feature.feature_intent_issues.find_by(issue: issue)
    expect(link).to be_present
    expect(link.release_state).to eq("held")
    expect(link.in_tree_dependencies.map(&:issue_id)).to contain_exactly(prerequisite.id)
  end

  it "keeps speculative alternatives visible in Paid without filing GitHub issues for them" do
    result = publish

    expect(feature.reload.speculative_alternatives).to include(
      hash_including("title" => "Alternative A", "summary" => "Still exploring this shape.")
    )
    expect(project.issues.where(title: "Alternative A")).not_to exist
    expect(client.created_issues.length).to eq(1)
    expect(result.speculative_alternatives.length).to eq(1)
  end

  it "reuses the published issue and local links when publication repeats" do
    publish
    second = publish

    expect(second).to be_published
    expect(second).to be_reused
    expect(client.created_issues.length).to eq(1)
    expect(feature.feature_intent_issues.where(issue_id: second.issue.id).count).to eq(1)
    expect(IssueDependency.where(issue_id: second.issue.id, depends_on_issue_id: prerequisite.id).count).to eq(1)
  end

  it "publishes distinct coherent tasks as distinct held issues" do
    first_result = publish
    second_result = publish(title: "Second coherent task")

    expect(first_result.issue.id).not_to eq(second_result.issue.id)
    expect(client.created_issues.length).to eq(2)
  end

  it "recovers a remotely created issue whose local record was lost" do
    published = publish
    published.issue.destroy!
    FeatureIntentIssue.where(feature_intent: feature).destroy_all
    client.remote_items << client.remote_issue(number: 4242, body: client.created_issues.first[:body])

    result = publish

    expect(result).to be_published
    expect(result).to be_reused
    expect(client.created_issues.length).to eq(1)
    expect(result.issue.github_number).to eq(4242)
    expect(feature.feature_intent_issues.where(issue_id: result.issue.id)).to exist
  end

  it "raises for retry when a recovered issue no longer has its planning hold" do
    published = publish
    published.issue.destroy!
    FeatureIntentIssue.where(feature_intent: feature).destroy_all
    client.remote_items << client.remote_issue(
      number: 4242,
      body: client.created_issues.first[:body],
      labels: []
    )

    expect { publish }.to raise_error(GithubClient::Error, /planning hold was not read back/)
    expect(feature.feature_intent_issues).to be_empty
  end

  it "preserves unrelated labels and human holds on a reused published issue" do
    published = publish
    published.issue.update!(labels: [ "planning", "human-hold" ])

    result = publish

    expect(result).to be_reused
    expect(result.issue.reload.labels).to contain_exactly("planning", "human-hold")
  end

  it "raises for retry when the remote read-back loses the publication marker" do
    client.read_back_body_override = "body without the marker"

    expect { publish }.to raise_error(GithubClient::Error, /was not read back/)
    expect(feature.feature_intent_issues).to be_empty
  end

  it "raises for retry when the remote read-back loses the planning hold" do
    client.read_back_labels_override = []

    expect { publish }.to raise_error(GithubClient::Error, /planning hold was not read back/)
    expect(feature.feature_intent_issues).to be_empty
  end

  it "does not publish planning-held issues for approval-gated features" do
    approval_gated_feature = create(:feature_intent, project: project)

    result = publish(feature_intent: approval_gated_feature)

    expect(result).not_to be_published
    expect(client.created_issues).to be_empty
  end

  it "links prerequisite facets with unknown coverage so readiness stays held" do
    facet = create(:feature_intent_facet, feature_intent: feature)
    direction = create(:feature_intent_facet_direction, feature_intent_facet: facet)

    result = publish(facet_prerequisites: [ { facet: facet, direction: direction, rationale: "Scope depends on this facet." } ])

    mapping = result.link.prerequisite_mapping
    expect(mapping).to be_present
    expect(mapping.coverage_assessment).to eq("unknown")
    expect(mapping.scope_revision).to be_present
    expect(mapping.prerequisites.map(&:feature_intent_facet)).to include(facet)
    expect(result.link.current_readiness_mapping["prerequisites"].length).to eq(1)

    readiness = FeatureIntents::ScopedReadiness.call(project: project, mapping: result.link.current_readiness_mapping)
    expect(readiness).not_to be_ready
    expect(FeatureIntents::ReleaseIssue.call(issue: result.issue)).not_to be_released
  end

  it "leaves a published link without facets on unknown readiness" do
    result = publish(facet_prerequisites: [])

    expect(result.link.prerequisite_mapping).to be_nil
    expect(result.link.current_readiness_mapping).to eq({})
    expect(FeatureIntents::ReleaseIssue.call(issue: result.issue)).not_to be_released
  end
end
