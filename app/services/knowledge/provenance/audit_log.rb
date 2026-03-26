# frozen_string_literal: true

module Knowledge
  module Provenance
    class AuditLog
      class << self
        def record(event:, project:, actor_type: nil, actor_id: nil,
                   target_type: nil, target_id: nil, details: {})
          event_attrs = {
            project: project,
            event_type: event.to_s,
            actor_type: actor_type,
            actor_id: actor_id&.to_s,
            target_type: target_type,
            target_id: target_id&.to_s,
            details: details
          }

          audit_event = KnowledgeAuditEvent.create(event_attrs)
          if audit_event.errors.any?
            Rails.logger.error(
              message: "knowledge.audit.persist_failed",
              event: event.to_s,
              project_id: project.id,
              errors: audit_event.errors.full_messages
            )
          end

          Rails.logger.info(
            message: "knowledge.audit",
            event: event.to_s,
            project_id: project.id,
            actor: [ actor_type, actor_id ].compact.join(":").presence,
            target: [ target_type, target_id ].compact.join(":").presence,
            details: details
          )

          audit_event
        end
      end
    end
  end
end
