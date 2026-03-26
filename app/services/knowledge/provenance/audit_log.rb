# frozen_string_literal: true

module Knowledge
  module Provenance
    class AuditLog
      class << self
        # actor: { type: "collector", id: "run_42" }
        # target: { type: "KnowledgeArtifact", id: "789" }
        def record(event:, project:, actor: nil, target: nil, details: {})
          actor_type, actor_id = extract_pair(actor)
          target_type, target_id = extract_pair(target)

          event_attrs = {
            project: project,
            event_type: event.to_s,
            actor_type: actor_type,
            actor_id: actor_id,
            target_type: target_type,
            target_id: target_id,
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
        # Each event hash uses the same keys as record: event:, project:, actor:, target:, details:
        def record_batch(events)
          return if events.empty?

          now = Time.current
          rows = events.map do |e|
            actor_type, actor_id = extract_pair(e[:actor])
            target_type, target_id = extract_pair(e[:target])

            {
              project_id: e[:project].id,
              event_type: e[:event].to_s,
              actor_type: actor_type,
              actor_id: actor_id,
              target_type: target_type,
              target_id: target_id,
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
              actor_type, actor_id = extract_pair(event[:actor])
              target_type, target_id = extract_pair(event[:target])

              record = KnowledgeAuditEvent.create(
                project: event[:project],
                event_type: event[:event].to_s,
                actor_type: actor_type,
                actor_id: actor_id,
                target_type: target_type,
                target_id: target_id,
                details: event[:details] || {}
              )
              if record.errors.any?
                Rails.logger.error(
                  message: "knowledge.audit.persist_failed",
                  event: event[:event].to_s,
                  project_id: event[:project].id,
                  errors: record.errors.full_messages
                )
              end
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
            actor_type, actor_id = extract_pair(e[:actor])
            target_type, target_id = extract_pair(e[:target])

            Rails.logger.info(
              message: "knowledge.audit",
              event: e[:event].to_s,
              project_id: e[:project].id,
              actor: [ actor_type, actor_id ].compact.join(":").presence,
              target: [ target_type, target_id ].compact.join(":").presence,
              details: e[:details] || {}
            )
          end
        end

        private

        # Normalize actor/target from { type: "X", id: "Y" } to [type, id_string]
        def extract_pair(hash)
          return [ nil, nil ] unless hash

          [ hash[:type], hash[:id]&.to_s ]
        end
      end
    end
  end
end
