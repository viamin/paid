# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagedCloseoutAdoption::Mappings do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:attributes) { { criterion_key: "Keeps history", stage: "pre_merge", phase: "coding", target_shape: "source_pr_head", execution_path: "technical_prerequisite", target_key: recipe.id, freshness_seconds: 60 } }
  let(:trusted_measurement_attributes) do
    attributes.merge(
      stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "digest_fixture", environment_class: "production"
    )
  end

  before do
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue), "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "Keeps history", "state" => "unmet" } ], "gaps" => []
    } })
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-007
  it "rejects a mapping supplied for a different project or source issue" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    other_issue = create(:issue, project:)

    expect(described_class.eligible_for(mapping:, project:, issue: other_issue).reason).to eq("mapping_scope_mismatch")
    expect(described_class.eligible_for(mapping:, project: create(:project), issue:).reason).to eq("mapping_scope_mismatch")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-007
  it "refuses changes to a reviewed mapping's bound inputs" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)

    expect(mapping.update(freshness_seconds: 7200)).to be(false)
    expect(mapping.reload.freshness_seconds).to eq(60)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-004
  it "invalidates admission after disable, revocation, or a changed reviewed recipe" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    expect(described_class.eligible_for(mapping:, project:, issue:)).to be_eligible

    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: false)
    expect(described_class.eligible_for(mapping:, project:, issue:).reason).to eq("project_not_enrolled")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-004
  it "admits an enabled phase under the conservative delegation posture" do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => true }
      }
    )
    expect(ProjectDelegation::Posture.resolve(project).level).to eq("conservative")
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)

    expect(described_class.eligible_for(mapping:, project:, issue:)).to be_eligible
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-003 STAGED-CLOSEOUT-ADOPTION-004
  it "rejects a mapping when the latest current assessment removes its criterion" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "A replacement criterion", "state" => "unmet" } ], "gaps" => []
    } })

    result = described_class.eligible_for(mapping:, project:, issue:)

    expect(result).not_to be_eligible
    expect(result.reason).to eq("criterion_not_current")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-004
  it "rejects a trusted measurement mapping when only its implementation changes" do
    with_mutable_check_source do |source_file, check_class|
      mapping = described_class.approve(
        project:, actor: maintainer, issue:,
        attributes: trusted_measurement_attributes
      )
      replace_check_source(source_file, check_class, "def call(project:) = project.account_id\n")
      result = described_class.eligible_for(mapping:, project:, issue:)

      expect(result).not_to be_eligible
      expect(result.reason).to eq("target_changed_or_unavailable")
    end
  end

  def with_mutable_check_source
    Tempfile.create([ "trusted_measurement", ".rb" ]) do |source_file|
      check_class = Class.new
      stub_const("TrustedMeasurements::Checks::DigestFixture", check_class)
      stub_const("TrustedMeasurements::ALLOWLIST", TrustedMeasurements::ALLOWLIST.merge("digest_fixture" => check_class.name))
      check_class.define_singleton_method(:version) { 1 }
      replace_check_source(source_file, check_class, "def call(project:) = project.id\n")
      yield source_file, check_class
    end
  end

  def replace_check_source(source_file, check_class, source)
    source_file.rewind
    source_file.truncate(0)
    source_file.write(source)
    source_file.flush
    source_file.rewind
    check_class.singleton_class.send(:remove_method, :call) if check_class.respond_to?(:call)
    check_class.singleton_class.class_eval(source_file.read, source_file.path, 1)
  end
end
