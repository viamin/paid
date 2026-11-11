# frozen_string_literal: true

require "digest"

module PartialCloseouts
  # Turns a validated semantic assessment into durable, replay-safe work owners.
  class Reconcile
    Attribution = Data.define(:source_issue, :owner_issue)
    MAX_GAPS = 10
    MAX_SYNC_CONFIRMATION_ATTEMPTS = 3
    VALID_REFERENCE_KINDS = %w[policy evidence].freeze
    VALID_WORKFLOWS = [ FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW,
      TechnicalPrerequisites::AUTHORIZATION_WORKFLOW ].freeze

    def self.call(...)
      new(...).call
    end

    # Gap states are keyed by assessment gap index; only indices inside the
    # assessment being reconciled describe the current pass. A retry with a
    # shorter, fresh assessment leaves deeper states behind as history, so
    # status and reassessment decisions must read the index-bounded view.
    def self.gap_states(assessment_gaps, reconciliation)
      states = reconciliation.to_h.fetch("gaps", {})
      Array(assessment_gaps).each_index.map { |index| states.fetch(index.to_s, {}) }
    end

    # The persisted status vocabulary, shared by finalize! and
    # PartialCloseouts::ConfirmSync so a confirmed sync repair cannot
    # relabel an unattributed prerequisite as ordinary operator work.
    def self.reconciliation_status(gap_states)
      statuses = gap_states.filter_map { |state| state["status"] }
      return "reassessment_required" if statuses.include?("attribution_unknown")
      return "awaiting_operator" if statuses.any? { |status| status.in?(%w[awaiting_operator awaiting_external]) }

      "reconciled"
    end

    def initialize(agent_run:, assessment:)
      @agent_run = agent_run
      @assessment = assessment.to_h.deep_stringify_keys
    end

    def call # @spec NO-OUTPUT-ISSUE-007 PARTIAL-CLOSEOUT-041
      validate!
      prerequisites_by_owner = reconcile_gaps
      publish_operator_prerequisites!(prerequisites_by_owner)
      reconcile_misplaced_prerequisite!(prerequisites_by_owner)
      publish_reassessment_requirement!
      publish_parent_dependencies!
      finalize!
    rescue GithubClient::Error => e
      record_failure!(e)
      raise
    end

    private

    attr_reader :agent_run, :assessment

    def gaps = assessment.fetch("gaps")

    def validate!
      raise ArgumentError, "partial closeout requires an issue" unless agent_run.issue
      raise ArgumentError, "gaps must be an array of at most #{MAX_GAPS}" unless gaps.is_a?(Array) && gaps.size <= MAX_GAPS

      gaps.each do |gap|
        raise ArgumentError, "gap criterion is required" if gap["criterion"].blank?
        if gap.key?("retain_on_source") && gap["retain_on_source"] != false &&
            !(gap["kind"] == "agent" && gap["retain_on_source"] == true && gap["owner_issue_number"].nil?)
          raise ArgumentError, "source retention is invalid"
        end
        # Mirrors Llm::AnalyzePartialCloseout#owner_resolvable? so the exact
        # operator next step reaches the Inbox notification; a generic
        # fallback would leave the prerequisite unactionable (#4119).
        raise ArgumentError, "human gap next_step is required" if human_gap?(gap) && gap["next_step"].to_s.strip.blank?
        validate_external_dependency!(gap) if external_gap?(gap)
        validate_human_references!(gap) if human_gap?(gap)
        validate_human_attribution!(gap) if human_gap?(gap)
        raise ArgumentError, "human gap workflow is invalid" if human_gap?(gap) && gap["workflow"].present? && !gap["workflow"].in?(VALID_WORKFLOWS)
      end
    end

    def validate_human_references!(gap)
      Array(gap["references"]).each do |reference|
        valid = reference.is_a?(Hash) && reference["kind"].in?(VALID_REFERENCE_KINDS) &&
          %w[key revision label].all? { |field| reference[field].to_s.strip.present? }
        raise ArgumentError, "human gap reference identity is invalid" unless valid
      end
      selection = gap["policy_selection"]
      return if selection.nil?

      valid_selection = selection.is_a?(Hash) && [ true, false ].include?(selection["required"])
      raise ArgumentError, "replacement policy selection is invalid" unless valid_selection
      return unless selection["required"]
      return if selection["next_step"].to_s.strip.present?

      raise ArgumentError, "replacement policy next_step is required"
    end

    # Attribution is semantic evidence supplied by the assessor. Ruby only
    # validates its stable identifiers and later verifies the referenced issue
    # still exists in this tenant; it never decides whether two prose criteria
    # mean the same thing.
    def validate_human_attribution!(gap)
      attribution = gap["attribution"]
      return if attribution.is_a?(Hash) && attribution["coverage"] == "unknown" && attribution["reason"].to_s.strip.present?

      valid = attribution.is_a?(Hash) && attribution["coverage"] == "established" &&
        attribution["source_issue_number"].is_a?(Integer) && attribution["source_issue_number"].positive? &&
        attribution["owner_issue_number"].is_a?(Integer) && attribution["owner_issue_number"].positive? &&
        attribution["criterion"].to_s.strip == gap["criterion"].to_s.strip
      raise ArgumentError, "human gap attribution is invalid" unless valid
    end

    def validate_external_dependency!(gap)
      dependency = gap["external_dependency"]
      valid = dependency.is_a?(Hash) && dependency["owner"].to_s.strip.present? &&
        dependency["repo"].to_s.strip.present? && dependency["number"].is_a?(Integer) && dependency["number"].positive?
      raise ArgumentError, "external dependency identity is invalid" unless valid
    end

    def human_gap?(gap) = gap["kind"] == "human"

    def external_gap?(gap) = gap["kind"] == "external"

    # Returns the non-agent gaps so every prerequisite is visible in one Inbox
    # notification: per-gap publishes dedup onto the same row and would
    # overwrite all but the last prerequisite.
    def reconcile_gaps
      prerequisites_by_owner = Hash.new { |hash, key| hash[key] = [] }
      gaps.each_with_index do |gap, index|
        if human_gap?(gap)
          attribution = attributed_source(gap)
          if attribution
            record_gap!(index, gap, status: "awaiting_operator", source_issue_id: attribution.source_issue.id,
              owner_issue_id: attribution.owner_issue.id)
            prerequisites_by_owner[attribution.owner_issue] << [ gap, attribution.source_issue ]
          else
            record_gap!(index, gap, status: "attribution_unknown", attribution_reason: gap.dig("attribution", "reason") || "The attributed source issue is unavailable.")
          end
        elsif external_gap?(gap)
          reconcile_external_gap(gap, index)
          prerequisites_by_owner[agent_run.issue] << [ gap, agent_run.issue ]
        else
          reconcile_agent_gap(gap, index)
        end
      end
      prerequisites_by_owner
    end

    def attributed_source(gap)
      attribution = gap.fetch("attribution")
      return if attribution["coverage"] == "unknown"

      source = agent_run.project.issues.find_by(github_number: attribution.fetch("source_issue_number"))
      owner = agent_run.project.issues.find_by(github_number: attribution.fetch("owner_issue_number"))
      return unless source && owner && source.github_state == "open" && owner.github_state == "open"

      Attribution.new(source, owner)
    end

    def reconcile_external_gap(gap, index)
      dependency = external_dependency(gap)
      # IssueDependency#normalize_external_ref downcases owner/repo on write, so a
      # mixed-case lookup here (Llm::AnalyzePartialCloseout accepts either case) would
      # miss the already-normalized row and collide with it on create.
      IssueDependency.find_or_create_by!(issue: agent_run.issue,
        depends_on_owner: dependency.fetch("owner").downcase, depends_on_repo: dependency.fetch("repo").downcase,
        depends_on_number: dependency.fetch("number"))
      record_gap!(index, gap, status: "awaiting_external")
    end

    def reconcile_agent_gap(gap, index)
      if gap["retain_on_source"] == true
        record_gap!(index, gap, status: "source_owned")
        return
      end

      owner = reusable_owner(gap) || create_owner!(gap, index)
      IssueDependency.find_or_create_by!(issue: agent_run.issue, depends_on_issue: owner)
      record_gap!(index, gap, owner_issue_id: owner.id, owner_issue_number: owner.github_number)
    end

    def reusable_owner(gap)
      number = gap["owner_issue_number"].to_i
      return if number.zero?

      owner = agent_run.project.issues.find_by(github_number: number, github_state: "open")
      reusable_owner_candidate(owner)
    end

    # A persisted replay owner can gain a dependency after its first use, so
    # every path that reuses an open owner must recheck trust and cycles.
    def reusable_owner_candidate(owner)
      # The parent cannot own its own residual gap; a self-referential edge
      # would fail IssueDependency#not_self_referential with
      # ActiveRecord::RecordInvalid, which is not a GithubClient::Error and
      # would bypass the retryable-failure path in +call+.
      return unless owner && owner.id != agent_run.issue.id
      trusted = agent_run.project.trusted_github_author_logins
      return if trusted.present? && !agent_run.project.trusted_github_author?(owner.github_creator_login)
      return if dependency_cycle?(owner)

      owner
    end

    def dependency_cycle?(owner)
      Issues::DependencyCycle.call(
        IssueDependency.new(issue: agent_run.issue, depends_on_issue: owner,
          cycle_provenance: "partial_closeout_owner_reuse")
      ).cycle?
    end

    def create_owner!(gap, index)
      prior_owner(index) || begin
        title = gap["title"].to_s.strip
        raise ArgumentError, "agent gap title is required" if title.blank?

        marker = owner_marker(index)
        existing = local_owner_with_marker(marker)
        return existing if existing
        recovered = recovered_remote_owner(marker) if creation_was_recorded?(index, marker)
        return recovered if recovered

        record_gap!(index, gap, status: "creating", marker: marker)
        created = agent_run.project.client.create_issue(
          agent_run.project.full_name,
          title: title.truncate(255), body: "#{gap["body"].to_s.strip}\n\n#{marker}", labels: owner_labels
        )
        # Persist the created number BEFORE the local upsert so a crash
        # between the GitHub call and the upsert is still recoverable on
        # retry via prior_owner's number lookup.
        record_gap!(index, gap, status: "creating", marker: marker, owner_issue_number: created.number)
        Issues::UpsertFromGithub.call(project: agent_run.project, github_issue: created)
      end
    end

    def owner_marker(index)
      "<!-- paid:partial-closeout:#{agent_run.id}:#{index} -->"
    end

    def local_owner_with_marker(marker)
      owner = agent_run.project.issues.where("body LIKE ?", "%#{marker}%").where(github_state: "open").first
      reusable_owner_candidate(owner)
    end

    # A worker can terminate after GitHub accepts create_issue but before the
    # response number is persisted. The durable pre-request marker distinguishes
    # that replay from a first attempt; recover the remote issue before sending
    # another create request.
    def creation_was_recorded?(index, marker)
      state = reconciliation.fetch("gaps", {}).fetch(index.to_s, {})
      state["status"] == "creating" && state["marker"] == marker
    end

    def recovered_remote_owner(marker)
      remote_owner = agent_run.project.client.search_issues(remote_owner_query(marker), per_page: 100).items
        .find { |issue| issue.body.to_s.include?(marker) }
      return unless remote_owner

      owner = Issues::UpsertFromGithub.call(project: agent_run.project, github_issue: remote_owner)
      reusable_owner_candidate(owner) if owner.github_state == "open"
    end

    def remote_owner_query(marker)
      %(repo:#{agent_run.project.full_name} is:issue state:open in:body "#{marker}")
    end

    # Same labeling convention as the other Paid-created issue paths so the
    # owner issue routes into automation (auto-pick) and is recognizable as
    # generated; without labels it sits unpicked on labeled projects.
    def owner_labels
      labels = []
      labels << agent_run.project.automation_label_name if agent_run.project.automation_on_label_enabled?
      labels << agent_run.project.generated_label_name if agent_run.project.auto_add_labels_enabled?
      labels
    end

    def prior_owner(index)
      state = reconciliation.fetch("gaps", {}).fetch(index.to_s, {})
      reusable_owner_candidate(owner_from_id(state) || owner_from_number(state))
    end

    def owner_from_id(state)
      return unless state["owner_issue_id"]

      agent_run.project.issues.find_by(id: state["owner_issue_id"], github_state: "open")
    end

    # Recovers a gap whose GitHub issue was created but whose local owner row
    # was never linked back (crash between create_issue and the upsert): the
    # replay state carries the created number, and a later sync may have
    # landed the row. Same parent exclusion as reusable_owner so a recorded
    # number pointing at the parent cannot create a self-referential edge.
    def owner_from_number(state)
      number = state["owner_issue_number"].to_i
      return if number.zero?

      owner = agent_run.project.issues.find_by(github_number: number, github_state: "open")
      owner if owner && owner.id != agent_run.issue.id
    end

    # @spec PARTIAL-CLOSEOUT-033
    def publish_operator_prerequisites!(prerequisites_by_owner)
      prerequisites_by_owner.each do |owner_issue, attributed_gaps|
        owner_issue.with_lock do
          previous = existing_prerequisite_notification(owner_issue)
          if previous
            previous.with_lock { publish_prerequisite_notification!(owner_issue, attributed_gaps, previous:) }
          else
            publish_prerequisite_notification!(owner_issue, attributed_gaps, previous: nil)
          end
        end
      end
    end

    # A notification can move only when this run previously published it and
    # the new assessment establishes attribution to a different owner. A
    # parent that still owns prerequisites keeps its notification, and an
    # empty map means no owner was established at all — unknown attribution
    # proves nothing about where the work belongs, so releasing on it would
    # waive a genuine human gate (#4893). Older unproven rows are
    # deliberately retained for operator review rather than deleted. A
    # shared owner's notification aggregates occurrences from several runs,
    # so only the occurrences this run published may move; any occurrence
    # another run still owns keeps the notification active.
    # @spec PARTIAL-CLOSEOUT-041
    def reconcile_misplaced_prerequisite!(prerequisites_by_owner)
      return if prerequisites_by_owner.key?(agent_run.issue) || prerequisites_by_owner.empty?

      notification = existing_prerequisite_notification(agent_run.issue)
      return unless notification&.active?

      owned, foreign = PrerequisiteOccurrences.for(notification)
        .partition { |occurrence| occurrence_origin(occurrence, notification) == agent_run.id }
      return if owned.empty?

      if foreign.empty?
        notification.update!(resolved_at: Time.current, metadata: notification.metadata.merge(
          "released_by" => "reconciled_attribution", "released_at" => Time.current.iso8601
        ))
      else
        prune_owned_prerequisites!(notification, foreign)
      end
    end

    # The proven-misplaced occurrences belong to this run alone; occurrences
    # other runs attributed to this owner keep their Action Required item.
    # Operator-facing fields are rebuilt from the retained set so no stale
    # criterion stays visible, and dropped references/evidence follow the
    # same supersede rules as a regular publish.
    # @spec PARTIAL-CLOSEOUT-041
    def prune_owned_prerequisites!(notification, retained)
      notification.update!(
        title: operator_prerequisite_title(retained),
        description: retained.map { |occurrence| operator_prerequisite_step(occurrence) }.join("\n"),
        metadata: prerequisite_metadata(retained, previous: notification)
      )
    end

    # Unknown attribution records a bounded reassessment requirement instead
    # of fabricating an Action Required human task: a non-blocking error
    # notification keeps the state visible on the issue (the closeout is
    # halted, and the next bounded assessment can self-resolve it — never
    # `blocking`, which would fabricate the human task the design forbids)
    # while the legacy sweep's bounded retry or an operator-requested fresh
    # audit re-attempts ownership. A later reconciliation that establishes
    # every attribution resolves the notice.
    # @spec PARTIAL-CLOSEOUT-041
    def publish_reassessment_requirement!
      unknowns = current_gap_states.select { |state| state["status"] == "attribution_unknown" }
      return resolve_reassessment_requirement if unknowns.empty?

      Notifications::Publish.call(
        account: agent_run.project.account, subject: agent_run.issue,
        source: REASSESSMENT_NOTIFICATION_SOURCE, severity: :error, blocking: false,
        title: reassessment_title(unknowns),
        description: unknowns.map { |state| reassessment_step(state) }.join("\n"),
        metadata: reassessment_metadata(unknowns)
      )
    end

    def resolve_reassessment_requirement
      Notifications::Resolve.call(
        account: agent_run.project.account, subject: agent_run.issue, source: REASSESSMENT_NOTIFICATION_SOURCE
      )
    end

    def reassessment_metadata(unknowns)
      { "origin_agent_run_id" => agent_run.id,
        "unknown_attribution" => unknowns.map { |state| { "criterion" => state["criterion"], "reason" => state["attribution_reason"] } },
        "recommended_action" => "Identify the issue that owns each unattributed prerequisite criterion, then request a fresh acceptance audit." }
    end

    def reassessment_title(unknowns)
      if unknowns.one?
        "A closeout prerequisite needs ownership reassessment"
      else
        "#{unknowns.size} closeout prerequisites need ownership reassessment"
      end
    end

    def reassessment_step(state)
      "#{state.fetch("criterion")}: #{state.fetch("attribution_reason", "The owning issue could not be established.").to_s.truncate(280)} Identify the owning issue, then request a fresh acceptance audit."
    end

    def publish_prerequisite_notification!(owner_issue, attributed_gaps, previous:)
      occurrences = merged_prerequisite_occurrences(attributed_gaps, previous)
      notification = Notifications::Publish.call(
        account: agent_run.project.account, subject: owner_issue,
        source: PREREQUISITE_NOTIFICATION_SOURCE, severity: :error, blocking: true,
        title: operator_prerequisite_title(occurrences),
        description: occurrences.map { |occurrence| operator_prerequisite_step(occurrence) }.join("\n"),
        metadata: prerequisite_metadata(occurrences, previous:)
      )
      ExternalPrerequisites.recheck(notification) if occurrences.any? { |occurrence| occurrence["kind"] == "external" }
    end

    # One owner's notification can carry prerequisites attributed by several
    # different runs — separate implementation children can each require the
    # same evidence owner — and Notifications::Publish replaces metadata
    # wholesale. Publishing only this run's subset would silently delete a
    # live operator gate another run recorded as awaiting_operator, so an
    # active prior notification's foreign occurrences are merged back in. A
    # resolved row is never resurrected: its occurrences were satisfied,
    # proven misplaced, or cleared by the owner's closure. An identity match
    # keeps the fresh revision this run just attributed either way.
    # @spec PARTIAL-CLOSEOUT-041
    def merged_prerequisite_occurrences(attributed_gaps, previous)
      current = attributed_gaps.map { |gap, source_issue| prerequisite_occurrence(gap, source_issue) }
      identities = current.map { |occurrence| occurrence.fetch("identity") }
      current + (previous&.active? ? foreign_prerequisite_occurrences(previous, identities) : [])
    end

    def foreign_prerequisite_occurrences(previous, retained_identities)
      PrerequisiteOccurrences.for(previous).reject do |occurrence|
        occurrence["identity"].in?(retained_identities) || occurrence_origin(occurrence, previous) == agent_run.id
      end
    end

    # Occurrences carry their originating run; rows persisted before
    # occurrence-level origin exist only as the notification's own origin.
    def occurrence_origin(occurrence, notification)
      occurrence["origin_agent_run_id"] || notification.metadata["origin_agent_run_id"]
    end

    # @spec PARTIAL-CLOSEOUT-031
    def prerequisite_metadata(occurrences, previous:)
      references = occurrences.flat_map { |occurrence| Array(occurrence["references"]) }
      identities = occurrences.map { |occurrence| occurrence.fetch("identity") }.sort
      identity = Digest::SHA256.hexdigest(JSON.generate(identities))
      metadata = { "origin_agent_run_id" => agent_run.id, "prerequisite_identity" => identity, "references" => references,
                   "prerequisites" => occurrences }
      workflow = workflow_for(occurrences)
      metadata["workflow"] = workflow if workflow
      submissions = reconciled_evidence_submissions(previous, occurrences)
      metadata["evidence_submissions"] = submissions if submissions.any?
      policy_selection = replacement_policy_action(occurrences)
      metadata["policy_selection"] = policy_selection if policy_selection

      superseded = superseded_references(previous, occurrences)
      metadata["superseded_references"] = superseded if superseded.any?
      metadata
    end

    # Only occurrences that actually dropped off the owner's notification
    # surrender their references; a publish that gained another run's
    # prerequisite must not supersede references that are still current.
    def superseded_references(previous, occurrences)
      retained = occurrences.map { |occurrence| occurrence["identity"] }
      dropped = prior_occurrences(previous).reject { |occurrence| occurrence["identity"].in?(retained) }
      (dropped.flat_map { |occurrence| Array(occurrence["references"]) } +
        Array(previous&.metadata&.fetch("superseded_references", nil))).uniq
    end

    def prior_occurrences(notification)
      return [] unless notification

      PrerequisiteOccurrences.for(notification)
    end

    def reconciled_evidence_submissions(previous, occurrences)
      prior_by_identity = prior_occurrences(previous).index_by { |occurrence| occurrence["identity"] }
      current_by_identity = occurrences.index_by { |occurrence| occurrence["identity"] }
      Array(previous&.metadata&.fetch("evidence_submissions", nil)).map do |submission|
        reconcile_evidence_submission(submission, prior_by_identity, current_by_identity)
      end
    end

    def reconcile_evidence_submission(submission, prior_by_identity, current_by_identity)
      source_revision = submission["source_revision"] || prior_by_identity.dig(submission["prerequisite_identity"], "source_revision")
      current_occurrence = current_by_identity[submission["prerequisite_identity"]]
      revision_current = source_revision.blank? || current_occurrence&.fetch("source_revision", nil) == source_revision
      return submission if current_occurrence && revision_current

      submission.merge(
        "source_revision" => source_revision,
        "outcome" => "stale",
        "reason" => "The closeout evidence changed; submit evidence for the current prerequisite revision."
      )
    end

    def prerequisite_identity(gap)
      identity = canonicalize(gap.slice("criterion", "kind", "next_step", "policy_selection", "workflow", "external_dependency", "attribution"))
      identity["references"] = Array(gap["references"])
        .map { |reference| canonicalize(reference) }
        .sort_by { |reference| JSON.generate(reference) }
      identity
    end

    # The occurrence is self-describing so a later run can merge it back
    # into the owner's notification: it carries the originating run, the
    # operator step, and the typed workflow / replacement-policy guidance
    # recorded at attribution time.
    def prerequisite_occurrence(gap, source_issue)
      occurrence = { "identity" => Digest::SHA256.hexdigest(JSON.generate(prerequisite_identity(gap))),
        "origin_agent_run_id" => agent_run.id,
        "criterion" => gap["criterion"], "kind" => gap["kind"], "next_step" => gap["next_step"].to_s.strip,
        "references" => Array(gap["references"]),
        "source_revision" => Assessment.source_revision_for(source_issue),
        "intent_revision" => Assessment.intent_revision_for(source_issue),
        "source_issue_number" => source_issue.github_number,
        "owner_issue_number" => gap.dig("attribution", "owner_issue_number") || source_issue.github_number }
      occurrence["external_dependency"] = external_dependency(gap) if external_gap?(gap)
      occurrence["workflow"] = gap["workflow"] if gap["workflow"].present?
      selection = gap["policy_selection"]
      occurrence["policy_selection"] = selection if selection.is_a?(Hash) && selection["required"]
      occurrence
    end

    def source_revision
      return @source_revision if defined?(@source_revision)

      @source_revision = assessment["source_revision"]
    end

    def canonicalize(value)
      case value
      when Hash
        value.sort.to_h.transform_values { |nested| canonicalize(nested) }
      when Array
        value.map { |nested| canonicalize(nested) }
      else
        value
      end
    end

    def replacement_policy_action(occurrences)
      steps = occurrences.filter_map do |occurrence|
        occurrence.dig("policy_selection", "next_step") if occurrence.dig("policy_selection", "required")
      end.uniq
      { "required" => true, "next_step" => steps.join(" ") } if steps.any?
    end

    def workflow_for(occurrences)
      workflows = occurrences.filter_map { |occurrence| occurrence["workflow"].presence }.uniq
      workflows.sole if workflows.one? && occurrences.all? { |occurrence| occurrence["workflow"] == workflows.sole }
    end

    def existing_prerequisite_notification(source_issue)
      Notification.find_by(
        account: agent_run.project.account, subject: source_issue,
        source: PREREQUISITE_NOTIFICATION_SOURCE
      )
    end

    def operator_prerequisite_title(occurrences)
      return "External prerequisite work is pending" if occurrences.all? { |occurrence| occurrence["kind"] == "external" }

      criteria = occurrences.map { |occurrence| occurrence["criterion"] }
      if criteria.one?
        "#{criteria.first} needs operator action"
      else
        "#{criteria.size} partial-closeout prerequisites need operator action"
      end
    end

    # validate! guarantees a nonblank exact step for every human gap, so the
    # Inbox item always tells the operator what to do — never a generic
    # "review the prerequisite" placeholder (#4119). Merged occurrences
    # carry their recorded step; legacy rows without one fall back to the
    # criterion alone rather than a fabricated instruction.
    def operator_prerequisite_step(occurrence)
      criterion = occurrence.fetch("criterion")
      step = occurrence["next_step"].to_s.strip
      dependency = occurrence["external_dependency"]
      if dependency
        reference = [ dependency.fetch("owner"), dependency.fetch("repo") ].join("/") + "#" + dependency.fetch("number").to_s
        "#{criterion}: #{step} Track #{reference}; Paid rechecks after its next sync."
      else
        step.present? ? "#{criterion}: #{step}" : criterion
      end
    end

    def publish_parent_dependencies! # @spec NO-OUTPUT-ISSUE-007
      # DependencyCycle reads this association while validating reusable owners.
      # Query through IssueDependency here so a newly persisted edge is visible
      # even when that earlier read populated the association cache.
      numbers = IssueDependency.where(issue: agent_run.issue).includes(:depends_on_issue)
        .filter_map { |dependency| dependency.depends_on_issue&.github_number }
      return if numbers.empty?

      # Base the rewrite on the live GitHub body, not the local copy, so
      # human edits made since the last sync survive (same pattern as
      # CreateMultipleIssuesActivity#update_parent_issue).
      body = agent_run.project.client.issue(agent_run.project.full_name, agent_run.issue.github_number).body.to_s
      updated_body = ProjectConventions::IssueDependencies.append_dependency_lines(
        project: agent_run.project, github_numbers: numbers, body:, resolved: dependency_conventions
      )
      return if updated_body == body

      agent_run.project.client.update_issue(agent_run.project.full_name, agent_run.issue.github_number, body: updated_body)
      record_pending_sync!(updated_body)
      agent_run.issue.update!(body: updated_body)
    end

    def record_pending_sync!(expected_body)
      sync_confirmation = {
        "status" => "pending",
        "attempts" => 0,
        "max_attempts" => MAX_SYNC_CONFIRMATION_ATTEMPTS,
        "expected_body_digest" => Digest::SHA256.hexdigest(expected_body),
        "requested_at" => Time.current.iso8601
      }
      agent_run.update!(reconciliation: reconciliation.merge(
        "status" => "pending_sync", "sync_confirmation" => sync_confirmation
      ))
    end

    def dependency_conventions
      @dependency_conventions ||= ProjectConventions::IssueDependencies.convention_value(agent_run.project)
    end

    def finalize!
      return if reconciliation.fetch("status", nil) == "pending_sync"

      states = current_gap_states
      unknown = states.count { |state| state["status"] == "attribution_unknown" }
      agent_run.update!(reconciliation: reconciliation.merge(
        "status" => self.class.reconciliation_status(states),
        "unknown_attribution_count" => unknown, "reconciled_at" => Time.current.iso8601))
    end

    def current_gap_states
      self.class.gap_states(gaps, reconciliation)
    end

    def record_failure!(error)
      agent_run.update!(reconciliation: reconciliation.merge("status" => "retryable_failure", "error" => error.message, "failed_at" => Time.current.iso8601))
    end

    def record_gap!(index, gap, attributes = {})
      state = reconciliation.fetch("gaps", {}).merge(index.to_s => gap.merge(attributes.stringify_keys))
      agent_run.update!(reconciliation: reconciliation.merge("gaps" => state, "status" => "reconciling"))
    end

    def reconciliation = agent_run.reconciliation.to_h.deep_stringify_keys

    def external_dependency(gap)
      gap.fetch("external_dependency").deep_stringify_keys
    end
  end
end
