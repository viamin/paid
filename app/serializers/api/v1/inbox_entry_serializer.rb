# frozen_string_literal: true

module Api
  module V1
    class InboxEntrySerializer
      def self.render(entry)
        new(entry).render
      end

      def initialize(entry)
        @entry = entry
      end

      def render
        common_fields.merge(questions: entry.questions, tasks: entry.tasks)
      end

      private

      attr_reader :entry

      def common_fields
        {
          id: entry.id,
          kind: entry.kind,
          waiting_since: entry.waiting_since&.iso8601,
          project: project,
          title: entry.title,
          summary: entry.summary,
          action_url: entry.action_url
        }
      end

      def project
        return unless entry.project

        { id: entry.project.id, owner: entry.project.owner, repo: entry.project.repo, name: entry.project.full_name }
      end
    end
  end
end
