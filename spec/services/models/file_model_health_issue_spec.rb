# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Models::FileModelHealthIssue do
  let(:client) { instance_double(GithubClient) }
  let(:project) do
    instance_double(
      Project,
      id: 1,
      full_name: "viamin/paid",
      generated_label_name: "paid-generated",
      automation_label_name: "paid-automation"
    )
  end

  def drift_result(new_models: { "openai" => { new_models: [ { base: "gpt-5.5", representative: "gpt-5.5", variants: 1 } ], deprecated_models: [] } }, fingerprint: "drift-fp")
    instance_double(
      Models::DetectCatalogDrift::Result,
      drift?: new_models.any?,
      providers: new_models,
      new_model_count: new_models.sum { |_p, d| d[:new_models].size },
      deprecated_model_count: new_models.sum { |_p, d| d[:deprecated_models].size },
      fingerprint: fingerprint
    )
  end

  def broken_result(findings: [], fingerprint: "broken-fp")
    instance_double(
      Models::DetectBrokenRunnerModels::Result,
      broken?: findings.any?,
      findings: findings,
      fingerprint: fingerprint
    )
  end

  before do
    allow(client).to receive(:create_label)
    allow(client).to receive(:add_comment)
    allow(client).to receive(:update_issue)
  end

  it "returns a noop when there are no findings" do
    result = described_class.call(
      project: project,
      drift: drift_result(new_models: {}),
      broken: broken_result(findings: []),
      client: client
    )

    expect(result.action).to eq(:noop)
    expect(client).not_to have_received(:create_label)
  end

  it "creates a labelled, auto-pick issue when no open issue exists" do
    allow(client).to receive_messages(issues: [], create_issue: OpenStruct.new(number: 7))

    result = described_class.call(project: project, drift: drift_result, broken: broken_result, client: client)

    expect(result.action).to eq(:created)
    expect(client).to have_received(:create_issue).with(
      "viamin/paid",
      hash_including(labels: array_including("model-health", "paid-generated", "paid-automation"))
    )
  end

  it "embeds the fingerprint marker and remediation guidance in the body" do
    allow(client).to receive(:issues).and_return([])
    allow(client).to receive(:create_issue) do |_repo, title:, body:, labels:|
      expect(body).to include("model-health-fingerprint:")
      expect(body).to include("agent-harness")
      OpenStruct.new(number: 7)
    end

    described_class.call(project: project, drift: drift_result, broken: broken_result, client: client)

    expect(client).to have_received(:create_issue)
  end

  it "skips when an open issue already carries the same fingerprint" do
    existing_fp = Digest::SHA256.hexdigest("drift-fp|broken-fp")
    existing = OpenStruct.new(number: 7, body: "<!-- model-health-fingerprint: #{existing_fp} -->")
    allow(client).to receive(:issues).and_return([ existing ])

    result = described_class.call(project: project, drift: drift_result, broken: broken_result, client: client)

    expect(result.action).to eq(:skipped)
    expect(client).not_to have_received(:add_comment)
  end

  it "comments and refreshes the body's fingerprint when findings change" do
    stale = OpenStruct.new(number: 7, body: "<!-- model-health-fingerprint: old -->")
    allow(client).to receive(:issues).and_return([ stale ])

    result = described_class.call(project: project, drift: drift_result, broken: broken_result, client: client)

    expect(result.action).to eq(:commented)
    expect(client).to have_received(:add_comment).with("viamin/paid", 7, kind_of(String))
    # Body is rewritten with the current fingerprint so the next run dedups
    # instead of commenting again.
    new_fp = Digest::SHA256.hexdigest("drift-fp|broken-fp")
    expect(client).to have_received(:update_issue).with(
      "viamin/paid", 7, body: include("model-health-fingerprint: #{new_fp}")
    )
  end
end
