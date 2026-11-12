# frozen_string_literal: true

module ProjectDelegation
  # Routes one focused Inbox decision to each in-flight delegated work item a
  # conservative rollback or an explicit hold affects. The decision names the
  # recovery that stays inside the admitted lineage, and it never touches the
  # admission snapshot, the delegated evidence, or the audit history it
  # refers to.
  #
  # @spec PROJECT-DELEGATION-010
  class RouteAffectedWork
    SOURCE = "project_delegation_pause"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, reason:, recovery:, title:, description:)
      @project = project
      @reason = reason.to_s
      @recovery = recovery.to_s
      @title = title
      @description = description
    end

    def call
      in_flight_authorizations.map do |authorization|
        Automation::FocusedDecision.call(
          account: project.account,
          subject: authorization.issue,
          source: SOURCE,
          title: title,
          description: description,
          metadata: {
            "authorization_id" => authorization.id,
            "reasons" => [ reason ],
            "recovery" => recovery
          }
        )
      end
    end

    private

    attr_reader :project, :reason, :recovery, :title, :description

    # The delegated work that is in force for the project right now. A
    # rollback or a hold affects it; revoked, expired, and superseded
    # authorizations already stopped on their own.
    def in_flight_authorizations
      project.bounded_delegated_actions
        .where(status: "active")
        .where("expires_at > ?", Time.current)
        .order(:id)
    end
  end
end
