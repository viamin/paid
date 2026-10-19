# frozen_string_literal: true

module FeatureIntents
  # The one deterministic admission gate for implementation work linked to
  # feature intents. An unreleased confidence link is reconciled before it is
  # denied, so direct API, chat, manual, and model-creation paths share the
  # automatic release contract with auto-pick. Already released links only
  # read their recorded evidence and never make a GitHub request.
  # An issue may serve several designs, so every linked feature intent must
  # permit the run. It intentionally reads the current feature state every
  # time: a run can be queued before a design becomes held again.
  # @spec FEATURE-APPROVAL-023 @spec FEATURE-APPROVAL-024 @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-005
  class RunAdmission
    Result = Data.define(:allowed, :revision, :reason, :snapshot) do
      def allowed? = allowed
    end

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      return denied("Issue has unresolved dependencies.") unless issue.ready_to_work?

      permits = links.map { |link| admit_link(link) }
      denial = permits.find { |result| !result.allowed? }
      return denial if denial

      permits.find { |result| result.revision.present? || result.snapshot.present? } || allowed
    end

    private

    attr_reader :issue

    # An issue may serve several designs (the issue_id index on the join is
    # not unique); each link carries its own admission contract, so every
    # link is evaluated rather than an arbitrary one.
    def links
      @links ||= FeatureIntentIssue.includes(:feature_intent, :prerequisite_mapping)
        .where(issue_id: issue.id)
        .order(:id).to_a
    end

    def admit_link(link)
      return confidence_admission(link) if link.feature_intent.confidence_driven?

      approval_admission(link.feature_intent)
    end

    def approval_admission(feature)
      return denied("Feature intent is not released.") unless feature.released?
      return denied("Feature intent has no approved repository revision.") if feature.approved_design_revision.blank?

      allowed(feature.approved_design_revision)
    end

    def confidence_admission(link)
      return reconcile_confidence_admission(link) unless link.release_state == "released"

      readiness = ScopedReadiness.call(project: issue.project, mapping: link.current_readiness_mapping)
      return denied(readiness.blockers.map(&:message).join(" ")) unless readiness.ready?
      return reconcile_changed_scope(link) unless link.release_snapshot["scope_revision"] == readiness.snapshot["scope_revision"]

      allowed(
        link.release_snapshot["merged_baseline"] || readiness.snapshot.dig("design_artifacts", 0, "revision"),
        snapshot: link.release_snapshot
      )
    end

    def reconcile_confidence_admission(link)
      result = ReleaseIssue.call(issue: issue)
      return denied(result.reason) unless result.released?

      confidence_admission(link.reload)
    end

    # A run has not been created yet, so its prior release snapshot may be
    # replaced by the revised scope. Existing runs retain their copied,
    # readonly snapshots.
    def reconcile_changed_scope(link)
      link.with_lock { link.update!(release_state: "held", released_at: nil, release_error: nil) }
      reconcile_confidence_admission(link)
    end

    def allowed(revision = nil, snapshot: {}) = Result.new(allowed: true, revision: revision, reason: nil, snapshot: snapshot)

    def denied(reason) = Result.new(allowed: false, revision: nil, reason: reason, snapshot: {})
  end
end
