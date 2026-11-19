# frozen_string_literal: true

require "digest"

module StagedCloseoutAdoption
  class Mappings
    Result = Data.define(:mapping, :reason) do
      def eligible? = reason.nil?
    end

    STAGE_PHASES = {
      "pre_merge" => [ Automation::Phases::CODING ],
      "merged_revision" => [ Automation::Phases::RELEASE_DEPLOYMENT ],
      "live_environment" => [ Automation::Phases::RELEASE_DEPLOYMENT, Automation::Phases::OPERATIONS ]
    }.freeze
    TARGET_SHAPES = {
      "pre_merge" => "source_pr_head",
      "merged_revision" => "source_pr_merged_revision",
      "live_environment" => "live_signal"
    }.freeze
    REQUIRED_ATTRIBUTES = %w[criterion_key stage phase target_shape execution_path target_key freshness_seconds].freeze

    def self.approve(...) = new(...).approve
    def self.revoke(mapping:, project:, actor:, issue:, attributes:)
      new(project:, actor:, issue:, attributes:).revoke(mapping)
    end
    def self.target_current?(mapping:, project:)
      new(project:).target_current?(mapping)
    end

    def self.eligible_for(mapping:, project:, issue:, observed_merge: false, observed_target: nil)
      new(project:, issue:).eligible_for(mapping, observed_merge:, observed_target:)
    end

    def initialize(project:, actor: nil, issue: nil, attributes: {})
      @project = project
      @actor = actor
      @issue = issue
      @attributes = attributes.stringify_keys
    end

    # @spec STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-003
    def approve
      authorize!
      raise Error, "issue does not belong to this project" unless issue.project_id == project.id
      raise Error, "staged closeout adoption is disabled" unless enrollment.enabled?

      validate_required_attributes!
      unless CloseoutVerifications::RetryPolicy.limit(attributes.fetch("retry_policy", {}))
        raise Error, "retry policy must permit between one and three total attempts"
      end
      validate_criterion!
      validate_stage!
      target = resolve_target!
      project.with_lock do
        revision = next_revision
        supersede_current!
        StagedCloseoutMapping.create!(mapping_attributes(target, revision))
      end
    end

    # @spec STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-004
    def revoke(mapping)
      authorize!
      raise Error, "mapping does not belong to this project" unless mapping.project_id == project.id

      mapping.with_lock do
        return mapping unless mapping.current?

        mapping.update!(status: "revoked", invalidated_by: actor, invalidated_at: Time.current, invalidation_reason: "revoked_by_reviewer")
      end
      mapping
    end

    # Used by #5074 at its future queue/claim boundary; it never authorizes a
    # run itself. The reason is deliberately inspectable on operator surfaces.
    # @spec STAGED-CLOSEOUT-ADOPTION-004 STAGED-CLOSEOUT-ADOPTION-007
    def eligible_for(mapping, observed_merge: false, observed_target: nil)
      return Result.new(mapping, "mapping_scope_mismatch") unless mapping.project_id == project.id &&
        mapping.account_id == project.account_id && issue&.project_id == project.id && mapping.issue_id == issue.id &&
        mapping.staged_closeout_enrollment_id == enrollment.id
      return Result.new(mapping, "project_not_enrolled") unless enrollment.enabled?
      return Result.new(mapping, "mapping_not_current") unless mapping.current?
      return Result.new(mapping, "source_issue_closed") unless Issue.where(id: issue.id, project_id: project.id, github_state: "open").exists?
      return Result.new(mapping, "retry_policy_invalid") unless CloseoutVerifications::RetryPolicy.limit(mapping.retry_policy)
      observed_stage = observed_target || ("merged_revision" if observed_merge)
      observed_stage = nil unless %w[merged_revision live_environment].include?(observed_stage) && mapping.stage == observed_stage
      return Result.new(mapping, "criterion_not_current") unless admission_criteria(observed_target: observed_stage).include?(mapping.criterion_key)
      return Result.new(mapping, "criterion_changed") unless criterion_digest(mapping.criterion_key) == mapping.criterion_digest
      return Result.new(mapping, "phase_policy_disabled") unless Automation::EffectivePolicy.call(
        project:, phase: mapping.phase, work_item: issue, trigger: :automatic
      ).permitted?
      return Result.new(mapping, "target_changed_or_unavailable") unless target_matches?(mapping)

      Result.new(mapping, nil)
    rescue Error => error
      Result.new(mapping, error.message)
    end

    # Revalidates a reviewed target without consulting the acceptance assessment,
    # whose source revision itself includes verification evidence.
    # @spec PARTIAL-CLOSEOUT-057
    def target_current?(mapping)
      mapping.project_id == project.id && target_matches?(mapping)
    rescue Error => error
      Rails.logger.info(message: "staged_closeout.target_unavailable", mapping_id: mapping.id, reason: error.message)
      false
    end

    private

    attr_reader :actor, :attributes, :issue, :project

    def enrollment
      @enrollment ||= project.staged_closeout_enrollment || project.build_staged_closeout_enrollment(account: project.account)
    end

    def authorize!
      raise Error, "actor is not authorized to manage this project" unless actor && ProjectPolicy.new(actor, project).update?
    end

    def validate_criterion!
      raise Error, "criterion is not current for this issue" unless criteria.include?(criterion_key)
    end

    def validate_required_attributes!
      missing = REQUIRED_ATTRIBUTES.reject { |key| attributes.key?(key) }
      raise Error, "missing required mapping attributes: #{missing.join(", ")}" if missing.any?
    end

    def criteria
      raise Error, "closeout assessment is stale" if assessment.stale?

      assessment.criteria.map { |criterion| criterion.fetch("criterion") }
    end

    # A newly observed target changes delivery evidence, not approved intent.
    # It may schedule a reviewed check but cannot satisfy acceptance itself.
    # @spec STAGED-CLOSEOUT-ADOPTION-010
    def admission_criteria(observed_target:)
      return criteria unless observed_target
      unless assessment.intent_revision == PartialCloseouts::Assessment.intent_revision_for(issue)
        raise Error, "closeout assessment is stale"
      end

      assessment.criteria.map { |criterion| criterion.fetch("criterion") }
    end

    def assessment
      @assessment ||= PartialCloseouts::Assessment.call(issue)
    end

    def criterion_key
      attributes.fetch("criterion_key")
    end

    def criterion_digest(key = criterion_key)
      StagedCloseoutMapping.digest_for(issue:, criterion_key: key)
    end

    def validate_stage!
      stage = attributes.fetch("stage")
      phase = attributes.fetch("phase")
      raise Error, "stage and phase do not match" unless STAGE_PHASES.fetch(stage, []).include?(phase)
      raise Error, "stage and target do not match" unless TARGET_SHAPES[stage] == attributes.fetch("target_shape")
      raise Error, "live environment mappings require an environment class" if stage == "live_environment" && attributes["environment_class"].blank?
      if attributes.fetch("execution_path") == "trusted_measurement" && stage != "live_environment"
        raise Error, "trusted measurements require a live environment target"
      end
    end

    def resolve_target!
      case attributes.fetch("execution_path")
      when "technical_prerequisite"
        requirement = PreCommitRequirement.resolve(project:, user: actor).find { |candidate| candidate.id == attributes.fetch("target_key").to_i }
        raise Error, "recipe is unavailable or unauthorized" unless requirement && !requirement.user_level?
        { key: requirement.id.to_s, version: requirement.updated_at.utc.iso8601, digest: Digest::SHA256.hexdigest([ requirement.id, requirement.command, requirement.check_type ].join("\0")) }
      when "trusted_measurement"
        key = attributes.fetch("target_key")
        check = TrustedMeasurements.check_class(key)
        { key:, version: check.version.to_s, digest: TrustedMeasurements.implementation_digest(key) }
      else
        raise Error, "execution path is not permitted"
      end
    rescue TrustedMeasurements::UnknownCheckError
      raise Error, "check is unavailable or unauthorized"
    end

    def mapping_attributes(target, revision)
      {
        account: project.account, project:, issue:, staged_closeout_enrollment: enrollment, reviewed_by: actor,
        criterion_key:, criterion_digest:, stage: attributes.fetch("stage"), phase: attributes.fetch("phase"),
        target_shape: attributes.fetch("target_shape"), execution_path: attributes.fetch("execution_path"),
        target_key: target[:key], target_version: target[:version], target_digest: target[:digest],
        environment_class: attributes["environment_class"], freshness_seconds: attributes.fetch("freshness_seconds"),
        retry_policy: attributes.fetch("retry_policy", {}), revision:, reviewed_at: Time.current
      }
    end

    def supersede_current!
      current_mappings.update_all(
        status: "superseded", invalidated_by_id: actor.id, invalidated_at: Time.current, invalidation_reason: "replaced_by_review"
      )
    end

    def current_mappings
      project.staged_closeout_mappings.where(issue:, criterion_key:).approved
    end

    def next_revision
      project.staged_closeout_mappings.where(issue:, criterion_key:).maximum(:revision).to_i + 1
    end

    def target_matches?(mapping)
      fresh = resolve_target_for(mapping)
      fresh[:version] == mapping.target_version && fresh[:digest] == mapping.target_digest
    end

    def resolve_target_for(mapping)
      original_attributes = @attributes
      @attributes = { "execution_path" => mapping.execution_path, "target_key" => mapping.target_key }
      resolve_target!
    ensure
      @attributes = original_attributes
    end
  end
end
