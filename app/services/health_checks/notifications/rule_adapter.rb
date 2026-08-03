# frozen_string_literal: true

require "digest"
require "json"

module HealthChecks
  module Notifications
    # Adapts cached per-project health-check findings into the existing
    # Notifications::Rule publish/resolve flow.
    # @spec HEALTH-CHECKS-001
    # @spec HEALTH-CHECKS-002
    # @spec HEALTH-CHECKS-003
    class RuleAdapter < ::Notifications::Rule
      SOURCE_PREFIX = "health_check".freeze
      NAV_SECTION = "projects"

      def call(scope:)
        Array(scope).each { |project| sync_project(project) }
      end

      private

      def sync_project(project)
        active_sources = current_entries(project).map do |entry|
          publish_entry(project, entry)
          entry.fetch(:source)
        end

        resolve_stale(project, active_sources)
      end

      def current_entries(project)
        findings = Array(HealthChecks::Cache.read(project)&.findings)
        subjects = preload_subjects(project, findings)

        findings
          .map { |finding| entry_for(project, finding, subjects:) }
          .uniq { |entry| entry.fetch(:source) }
      end

      def entry_for(project, finding, subjects:)
        {
          source: notification_source(project, finding),
          subject: notification_subject(project, finding, subjects:),
          attributes: notification_attributes(project, finding)
        }
      end

      def publish_entry(project, entry)
        ::Notifications::Publish.call(
          account: project.account,
          source: entry.fetch(:source),
          subject: entry.fetch(:subject),
          **entry.fetch(:attributes)
        )
      end

      def resolve_stale(project, active_sources)
        existing_notifications(project).find_each do |notification|
          next if active_sources.include?(notification.source)

          ::Notifications::Resolve.call(
            account: project.account,
            source: notification.source,
            subject: notification.subject
          )
        end
      end

      def existing_notifications(project)
        ::Notification.active
          .where(account: project.account)
          .where("source LIKE ?", source_prefix(project))
      end

      def source_prefix(project)
        "#{SOURCE_PREFIX}/project/#{project.id}/%"
      end

      def notification_source(project, finding)
        [
          SOURCE_PREFIX,
          "project",
          project.id,
          finding.code,
          finding.subject_type || project.class.name,
          finding.subject_id || project.id,
          metadata_fingerprint(finding.metadata)
        ].join("/")
      end

      def metadata_fingerprint(metadata)
        Digest::SHA256.hexdigest(JSON.generate(normalize_value(metadata.to_h)))[0, 12]
      end

      def normalize_value(value)
        case value
        when Hash
          value.to_h.sort_by { |key, _| key.to_s }.to_h { |key, nested| [ key.to_s, normalize_value(nested) ] }
        when Array
          value.map { |nested| normalize_value(nested) }
        else
          value
        end
      end

      def preload_subjects(project, findings)
        findings
          .group_by { |finding| subject_class_for(finding) }
          .each_with_object({}) do |(subject_class, grouped_findings), subjects|
            next unless subject_class

            ids = grouped_findings.filter_map(&:subject_id).uniq
            next if ids.empty?

            subjects[subject_class.name] = subject_class.where(id: ids).index_by(&:id)
          end
      end

      def notification_subject(project, finding, subjects:)
        subject_class = subject_class_for(finding)
        return project unless subject_class

        subjects.dig(subject_class.name, finding.subject_id) || project
      end

      def subject_class_for(finding)
        subject_class = finding.subject_type&.safe_constantize
        return unless finding.subject_id && subject_class&.<(ApplicationRecord)

        subject_class
      end

      def notification_attributes(project, finding)
        {
          severity: finding.severity,
          title: finding.title,
          description: notification_description(finding),
          nav_section: NAV_SECTION,
          action_url: project_health_check_path(project),
          metadata: notification_metadata(project, finding)
        }
      end

      def notification_description(finding)
        [ finding.description, finding.remediation ].compact.join(" ")
      end

      def notification_metadata(project, finding)
        finding.metadata.to_h.merge(
          health_check_code: finding.code,
          health_check_scope: finding.scope.to_s,
          health_check_subject_type: finding.subject_type,
          health_check_subject_id: finding.subject_id,
          project_id: project.id
        ).compact
      end
    end
  end
end
