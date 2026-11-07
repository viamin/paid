# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Focused re-decision routing for settled intent (RDR-080): downstream
    # boundaries consult this gate before delegated work may proceed over —
    # or re-ask — material questions.
    #
    # - A current settlement permits: the bound design and acceptance
    #   revisions still match, so the settled answers travel with the work
    #   and no phase may ask the same question again.
    # - A pending or rejected checkpoint blocks until a human settles.
    # - A revision delta routes exactly one focused Inbox decision naming
    #   the smallest affected question set, its recommendation and
    #   consequences, the revision delta, evidence, and the next action.
    #   Unrelated settled questions are not reopened.
    #
    # Revision-token comparison is the mechanical trigger; the semantic
    # conflict/invalidation/expansion judgment stays with the humans the
    # focused decision reaches.
    # @spec PROJECT-DELEGATION-002
    class Gate
      REDECISION_SOURCE = "project_delegation_intent_redecision"

      STATES = %i[permitted pending rejected revision_delta no_material_questions].freeze
      BLOCKING_STATES = %i[pending rejected revision_delta].freeze

      Result = Data.define(:state, :settlement, :checkpoint, :current_revisions, :affected_groups, :notification) do
        def permitted? = state == :permitted || state == :no_material_questions
        def blocked? = BLOCKING_STATES.include?(state)
      end

      def self.call(project:, issue:, assessment: nil)
        checkpoint = issue.delegation_intent_checkpoints.where.not(status: "superseded").order(id: :desc).first
        if checkpoint.nil?
          return Result.new(state: :no_material_questions, settlement: nil, checkpoint: nil,
            current_revisions: {}, affected_groups: [], notification: nil) unless Plan.call(project: project, issue: issue).material?

          # Material questions are known but nothing is reviewable yet: open
          # the checkpoint (and its Inbox request) so the block is actionable.
          checkpoint = Open.call(project: project, issue: issue)
          return Result.new(state: :pending, settlement: nil, checkpoint: checkpoint,
            current_revisions: {}, affected_groups: [], notification: nil)
        end

        revisions = Revisions.for(issue, assessment: assessment)
        plan = Plan.call(project: project, issue: issue)
        settlement = checkpoint.settlement
        state = state_for(checkpoint, settlement, revisions, plan)
        affected = state == :revision_delta ? affected_groups(checkpoint, plan) : []
        notification = state == :revision_delta ? publish_redecision(checkpoint, settlement, revisions, affected) : nil
        Result.new(
          state: state,
          settlement: settlement,
          checkpoint: checkpoint,
          current_revisions: revisions,
          affected_groups: affected,
          notification: notification
        )
      end

      # A DelegatedWorkBoundary-shaped result so admission boundaries can
      # surface a checkpoint stop with the notification they must route.
      def self.boundary_result(gate, boundary)
        Automation::DelegatedWorkBoundary::Result.new(
          permitted: false,
          boundary: boundary,
          reasons: [ "intent_checkpoint_#{gate.state}" ],
          notification: gate.notification
        )
      end

      # The settled answers hold while the bound revisions are current AND the
      # current question set matches what was settled. A moved revision is new
      # evidence that may conflict with or invalidate the settlement; a
      # changed question set is evidence that materially expands it. Both are
      # mechanical triggers — the semantic judgment stays with the humans the
      # focused decision reaches. When no material question remains, nothing
      # gates delegated work.
      def self.state_for(checkpoint, settlement, revisions, plan)
        return :no_material_questions unless plan.material?
        return :pending unless settlement
        return :rejected if settlement.rejected?
        return :revision_delta unless checkpoint.settlement_current?(revisions)
        return :revision_delta if plan.question_set_digest != checkpoint.question_set_digest

        :permitted
      end

      # The smallest affected question set: groups in the settled checkpoint
      # whose question changed or disappeared, and groups new to the current
      # plan. Unchanged groups stay settled and are never reopened.
      def self.affected_groups(checkpoint)
        settled = Array(checkpoint.question_groups).index_by { |group| group["key"] }
        current = Plan.call(project: checkpoint.project, issue: checkpoint.issue).groups
        current.filter_map do |group|
          next nil if settled[group.key] && Plan.normalize_question(settled[group.key]["question"]) == Plan.normalize_question(group.question)

          group.to_h.transform_keys(&:to_s)
        end
      end

      def self.publish_redecision(checkpoint, settlement, revisions, affected)
        Notifications::Publish.call(
          account: checkpoint.account,
          subject: checkpoint.issue,
          source: REDECISION_SOURCE,
          severity: :error,
          blocking: true,
          nav_section: "projects",
          title: "New evidence may change settled intent",
          description: redecision_description(checkpoint, settlement, revisions, affected),
          metadata: {
            "settlement_id" => settlement.id,
            "checkpoint_id" => checkpoint.id,
            "bound_design_revision" => settlement.design_revision,
            "current_design_revision" => revisions.fetch("design_revision"),
            "bound_acceptance_revision" => settlement.acceptance_revision,
            "current_acceptance_revision" => revisions.fetch("acceptance_revision"),
            "bound_question_set_digest" => checkpoint.question_set_digest,
            "affected_groups" => affected,
            "recommended_action" => "Open a new intent checkpoint and settle the changed questions."
          }
        )
      end

      def self.redecision_description(checkpoint, settlement, revisions, affected)
        names = affected.map { |group| group["question"] }.compact
        scope = names.empty? ? "The settled questions" : "#{names.size} changed question#{'s' if names.size != 1}"
        "#{scope} on issue ##{checkpoint.issue.github_number} need one focused re-decision: " \
          "#{delta_summary(checkpoint, settlement, revisions).to_sentence}."
      end

      # What moved since settlement: bound design/acceptance revisions and/or
      # the material question set itself (a material expansion).
      def self.delta_summary(checkpoint, settlement, revisions)
        deltas = []
        if settlement.design_revision != revisions.fetch("design_revision")
          deltas << "design revision #{settlement.design_revision[0, 12]} → #{revisions.fetch('design_revision')[0, 12]}"
        end
        if settlement.acceptance_revision != revisions.fetch("acceptance_revision")
          deltas << "acceptance revision #{settlement.acceptance_revision[0, 12]} → #{revisions.fetch('acceptance_revision')[0, 12]}"
        end
        deltas << "the material question set changed" if deltas.empty?
        deltas
      end

      private_class_method :state_for, :affected_groups, :publish_redecision, :redecision_description, :delta_summary
    end
  end
end
