# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Invalidation do
  let(:dependencies) do
    { "environment" => { "immutable" => true, "digest" => "sha256:runtime" },
      "producer_versions" => { "paid" => "1.2.3" },
      "tool_versions" => { "tlc_runtime_image_digest" => "sha256:runtime" } }
  end

  # @spec LAYERED-VERIFY-019
  it "reuses evidence with a complete matching dependency basis and invalidates changed or unknown dependencies" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:,
      source_reference: obligation.canonical_source_path, target_reference: "app/models/payment.rb")
    scope_paths = [ "app/models/payment.rb", obligation.canonical_source_path ]
    matching = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2",
      "dependencies" => dependencies, "scope_paths" => scope_paths
    })
    changed = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v2",
      "dependencies" => dependencies
    })
    incomplete = create(:layered_verification_check_result, obligation:, input_revision: { "code" => "code-v2" })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:)

    expect(impact.reusable_result_ids).to eq([ matching.id ])
    expect(impact.invalidated_result_ids).to contain_exactly(changed.id, incomplete.id)
    expect(impact.limitations).to include(a_string_matching(/complete dependency and scope-impact basis/))
    expect(changed.reload.execution_state).to eq("completed")
  end

  # @spec LAYERED-VERIFY-019
  it "invalidates evidence from producers the carry-forward path cannot record" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:,
      source_reference: obligation.canonical_source_path, target_reference: "app/models/payment.rb")
    result = create(:layered_verification_check_result, obligation:, producer: "semantic_audit", input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2",
      "dependencies" => dependencies,
      "scope_paths" => [ "app/models/payment.rb", obligation.canonical_source_path ]
    })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:)

    expect(impact.reusable_result_ids).to be_empty
    expect(impact.invalidated_result_ids).to eq([ result.id ])
  end

  # @spec LAYERED-VERIFY-019
  it "reuses cross-revision evidence when the complete declared scope is unchanged" do
    project = create(:project)
    github_client = instance_double(GithubClient)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:,
      source_reference: obligation.canonical_source_path, target_reference: "app/models/payment.rb")
    allow(github_client).to receive(:compare).with(project.full_name, "code-v1", "code-v2")
      .and_return(Struct.new(:files).new([ Struct.new(:filename).new("README.md") ]))
    result = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v2", "dependencies" => dependencies,
      "scope_paths" => [ "app/models/payment.rb", obligation.canonical_source_path ]
    })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:, github_client:)

    expect(impact.reusable_result_ids).to eq([ result.id ])
    expect(impact.invalidated_result_ids).to be_empty
  end

  # @spec LAYERED-VERIFY-019
  it "invalidates same-revision evidence when the complete declared scope changed" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:,
      source_reference: obligation.canonical_source_path, target_reference: "app/models/payment.rb")
    result = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2", "dependencies" => dependencies,
      "scope_paths" => [ obligation.canonical_source_path ]
    })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:)

    expect(impact.invalidated_result_ids).to eq([ result.id ])
    expect(impact.reusable_result_ids).to be_empty
  end

  # @spec LAYERED-VERIFY-019
  it "invalidates cross-revision evidence when a scoped path changed or comparison is truncated" do
    project = create(:project)
    github_client = instance_double(GithubClient)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:,
      source_reference: obligation.canonical_source_path, target_reference: "app/models/payment.rb")
    result = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v2", "dependencies" => dependencies,
      "scope_paths" => [ "app/models/payment.rb", obligation.canonical_source_path ]
    })
    allow(github_client).to receive(:compare).and_return(
      Struct.new(:files).new([ Struct.new(:filename).new("app/models/payment.rb") ]),
      Struct.new(:files).new(Array.new(300) { |index| Struct.new(:filename).new("changed-#{index}.rb") })
    )

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:, github_client:)
    truncated = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:, github_client:)

    expect(impact.invalidated_result_ids).to eq([ result.id ])
    expect(truncated.invalidated_result_ids).to eq([ result.id ])
  end

  # @spec LAYERED-VERIFY-019
  it "invalidates cross-revision evidence when a scoped path was renamed" do
    project = create(:project)
    github_client = instance_double(GithubClient)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    create(:layered_verification_correspondence_claim, obligation:,
      source_reference: obligation.canonical_source_path, target_reference: "app/models/payment.rb")
    result = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v2", "dependencies" => dependencies,
      "scope_paths" => [ "app/models/payment.rb", obligation.canonical_source_path ]
    })
    comparison_file = Struct.new(:filename, :previous_filename)
      .new("app/models/archived_payment.rb", "app/models/payment.rb")
    allow(github_client).to receive(:compare)
      .and_return(Struct.new(:files).new([ comparison_file ]))

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2", dependencies:, github_client:)

    expect(impact.invalidated_result_ids).to eq([ result.id ])
    expect(impact.reusable_result_ids).to be_empty
  end

  # @spec LAYERED-VERIFY-019
  it "invalidates matching hashes when concrete runtime or producer versions are absent" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:, external_revision: "intent-v2")
    result = create(:layered_verification_check_result, obligation:, input_revision: {
      "code" => "code-v2", "external_revision" => "intent-v2",
      "dependencies" => { "environment" => "isolated_execution_environment", "producer_versions" => { "paid" => "unversioned" } }
    })

    impact = described_class.call(obligations: [ obligation ], target_revision: "code-v2",
      dependencies: result.input_revision.fetch("dependencies"))

    expect(impact.invalidated_result_ids).to eq([ result.id ])
    expect(impact.reusable_result_ids).to be_empty
  end
end
