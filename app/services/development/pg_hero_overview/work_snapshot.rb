# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Reads before publishing. GitHub comments are never included in this input.
    # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-033
    class WorkSnapshot
      FINDING_MARKER = /<!-- pghero-(?:overview-finding|repair-covers): ([^\s]+) -->/
      MANAGED_FINDING_MARKER = /<!-- pghero-overview-finding: [^\s]+ -->/
      REPAIR_MARKER = /<!-- pghero-overview-repair: ([^\s]+) -->/
      CLOSING_REFERENCE = /^(?:fixes|closes|resolves)\s+#(\d+)\s*$/i

      attr_reader :records, :work_items

      def initialize(project:, client:)
        @project = project
        open_work = client.all_issues(project.full_name, state: "open")
        history = client.all_issues(project.full_name, labels: IssueFiler::LABEL, state: "all")
        @records = (open_work + history).uniq { |record| record.number.to_i }
        tracked_numbers = PgHeroOverviewFinding.where(project: project).where.not(github_issue_number: nil)
          .distinct.pluck(:github_issue_number)
        (tracked_numbers - @records.map { |record| record.number.to_i }).each do |number|
          @records << client.issue(project.full_name, number)
        end
        locals = project.issues.where(github_number: @records.map(&:number)).index_by(&:github_number)
        @records.select! do |record|
          author = record.respond_to?(:user) ? record.user&.login : nil
          local = locals[record.number.to_i]
          project.trusted_github_author?(author) && (local.nil? || local.trusted?)
        end
        @work_items = @records.select { |record| record.state == "open" }.map { |record| attributes(record) }
      end

      def issue(number)
        records.find { |record| record.number.to_i == number && !pull_request?(record) }
      end

      def pull_request?(record)
        record.respond_to?(:pull_request) && record.pull_request.present?
      end

      def finding_keys(record)
        record.body.to_s.scan(FINDING_MARKER).flatten.uniq
      end

      def managed_issue?(record)
        return false if record.nil? || pull_request?(record)

        record.body.to_s.match?(MANAGED_FINDING_MARKER) || repair_key(record).present?
      end

      def repair_key(record)
        record.body.to_s[REPAIR_MARKER, 1]
      end

      def closing_numbers(record)
        record.body.to_s.scan(CLOSING_REFERENCE).flatten.map(&:to_i).uniq
      end

      private

      def attributes(record)
        {
          "number" => record.number.to_i,
          "kind" => pull_request?(record) ? "pull_request" : "issue",
          "title" => record.title.to_s.truncate(255),
          "body" => record.body.to_s.truncate(3_000),
          "finding_keys" => finding_keys(record),
          "closing_issue_numbers" => closing_numbers(record)
        }
      end
    end
  end
end
