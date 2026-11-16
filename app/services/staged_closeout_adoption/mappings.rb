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

    def self.approve(...) = new(...).approve
    def self.revoke(mapping:, project:, actor:, issue:, attributes:)
      new(project:, actor:, issue:, attributes:).revoke(mapping)
    end
    def self.eligible_for(mapping:, project:, issue:)
      new(project:, issue:).eligible_for(mapping)
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

      mapping.update!(status: "revoked", invalidated_at: Time.current, invalidation_reason: "revoked_by_reviewer")
      mapping
    end

    # Used by #5074 at its future queue/claim boundary; it never authorizes a
    # run itself. The reason is deliberately inspectable on operator surfaces.
    # @spec STAGED-CLOSEOUT-ADOPTION-004
    def eligible_for(mapping)
      return Result.new(mapping, "project_not_enrolled") unless enrollment.enabled?
      return Result.new(mapping, "mapping_not_current") unless mapping.current?
      return Result.new(mapping, "criterion_changed") unless criterion_digest(mapping.criterion_key) == mapping.criterion_digest
      return Result.new(mapping, "phase_policy_disabled") unless Automation::EffectivePolicy.call(
        project:, phase: mapping.phase, work_item: issue, trigger: :automatic, delegated_action: "review"
      ).permitted?
      return Result.new(mapping, "target_changed_or_unavailable") unless target_matches?(mapping)

      Result.new(mapping, nil)
    rescue Error => error
      Result.new(mapping, error.message)
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

    def criteria
      PartialCloseouts::Assessment.call(issue).criteria.map { |criterion| criterion.fetch("criterion") }
    end

    def criterion_key
      attributes.fetch("criterion_key")
    end

    def criterion_digest(key = criterion_key)
      Digest::SHA256.hexdigest([ issue.id, key, PartialCloseouts::Assessment.intent_revision_for(issue) ].join("\0"))
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
        raise Error, "recipe is unavailable or unauthorized" unless requirement
        { key: requirement.id.to_s, version: requirement.updated_at.utc.iso8601, digest: Digest::SHA256.hexdigest([ requirement.id, requirement.command, requirement.check_type ].join("\0")) }
      when "trusted_measurement"
        key = attributes.fetch("target_key")
        check = TrustedMeasurements.check_class(key)
        { key:, version: check.version.to_s, digest: Digest::SHA256.hexdigest([ key, check.version, check.name ].join("\0")) }
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
      current_mappings.update_all(status: "superseded", invalidated_at: Time.current, invalidation_reason: "replaced_by_review")
    end

    def current_mappings
      project.staged_closeout_mappings.where(issue:, criterion_key:).approved
    end

    def next_revision
      current_mappings.maximum(:revision).to_i + 1
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
