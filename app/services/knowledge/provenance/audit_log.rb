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

          audit_event = begin
            record = KnowledgeAuditEvent.create(event_attrs)
            if record.errors.any?
              Rails.logger.error(
                message: "knowledge.audit.persist_failed",
                event: event.to_s,
                project_id: project.id,
                errors: record.errors.full_messages
              )
            end
            record
          rescue StandardError => e
            Rails.logger.error(
              message: "knowledge.audit.persist_failed",
              event: event.to_s,
              project_id: project.id,
              error_class: e.class.name,
              error_message: e.message
            )
            nil
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

        # Bulk-insert audit events for a batch of targets to avoid N+1 inserts.
        # Skips individual validations for performance; callers must ensure data integrity.
        def record_batch(events)
          return if events.empty?

          now = Time.current
          rows = events.map do |e|
            {
              project_id: e[:project].id,
              event_type: e[:event].to_s,
              actor_type: e[:actor_type],
              actor_id: e[:actor_id]&.to_s,
              target_type: e[:target_type],
              target_id: e[:target_id]&.to_s,
              details: e[:details] || {},
              created_at: now
            }
          end

          begin
            KnowledgeAuditEvent.insert_all(rows)
          rescue StandardError => e
            Rails.logger.error(
              message: "knowledge.audit.persist_failed",
              error_class: e.class.name,
              error_message: e.message,
              rows_count: rows.size
            )

            # Best-effort per-row fallback so one bad row doesn't lose all events
            events.each do |event|
              KnowledgeAuditEvent.create(
                project: event[:project],
                event_type: event[:event].to_s,
                actor_type: event[:actor_type],
                actor_id: event[:actor_id]&.to_s,
                target_type: event[:target_type],
                target_id: event[:target_id]&.to_s,
                details: event[:details] || {}
              )
            rescue StandardError => row_error
              Rails.logger.error(
                message: "knowledge.audit.persist_failed",
                event: event[:event].to_s,
                project_id: event[:project].id,
                error_class: row_error.class.name,
                error_message: row_error.message
              )
            end
          end

          events.each do |e|
            Rails.logger.info(
              message: "knowledge.audit",
              event: e[:event].to_s,
              project_id: e[:project].id,
              actor: [ e[:actor_type], e[:actor_id] ].compact.join(":").presence,
              target: [ e[:target_type], e[:target_id] ].compact.join(":").presence,
              details: e[:details] || {}
            )
          end
        end
      end
    end
  end
end
