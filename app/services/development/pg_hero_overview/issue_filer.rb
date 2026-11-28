# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Persists repair coverage and maintains one lifecycle for all its observations.
    # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-028 RAILS-CONTROL-PLANE-029
    #   RAILS-CONTROL-PLANE-033 RAILS-CONTROL-PLANE-034
    class IssueFiler
      LABEL = "pghero-overview"
      IDENTITY_MARKER = "pghero-overview-finding"
      FINGERPRINT_MARKER = "pghero-overview-fingerprint"
      DEFAULT_CAP = Policy::MAX_NEW_ISSUES_PER_RUN
      BODY_TEXT_LIMIT = 1_500

      Result = Data.define(:created, :updated, :reopened, :closed, :deferred, :deferred_keys,
        :planning_error, :repair_plans, :assessed_keys)

      def initialize(project:, client:, dashboard_base_url: nil, cap: DEFAULT_CAP, now: -> { Time.current }, dry_run: false)
        @dry_run = dry_run
        @project = project
        @client = client
        @dashboard_base_url = dashboard_base_url || ENV.fetch("PAID_PGHERO_BASE_URL", "http://localhost:3000")
        @cap = cap
        @now = now
      end

      def sync(observed_findings:, actionable_findings:, rows:, collected_categories:)
        @snapshot = WorkSnapshot.new(project: @project, client: @client)
        @counts = { created: 0, updated: 0, reopened: 0, closed: 0 }
        @plans = []
        @actionable_identities = actionable_findings.map(&:identity).to_set
        observed = observed_findings.index_by(&:identity)
        observed_findings.each do |finding|
          rows[finding.key] ||= findings_scope.find_or_initialize_by(database: finding.database, finding_key: finding.key)
          row = rows.fetch(finding.key)
          row.update!(finding_type: finding.type, observation: finding.to_h.as_json,
            first_seen_at: row.first_seen_at || @now.call, last_seen_at: @now.call,
            consecutive_observations: [ row.consecutive_observations.to_i, 1 ].max, resolved_at: nil)
        end
        recover_owners
        import_pr_coverage
        pending = actionable_findings.select do |finding|
          row = rows.fetch(finding.key).reload
          repair = row.repair
          if repair && !repair.managed_issue && @snapshot.work_items.none? { |item|
            item["number"] == repair.github_issue_number || item["number"] == repair.github_pr_number
          }
            row.update!(repair: nil)
          end
          row.repair_id.nil?
        end
        planning_error = nil
        assessed_keys = []
        begin
          assessment = PlanRepairs.new(project: @project, findings: pending,
            work_items: @snapshot.work_items,
            assessments: pending.to_h { |finding| [ finding.identity, rows.fetch(finding.key).assessment ] },
            existing_repairs: repairs_scope.includes(:findings).map do |repair|
              { title: repair.title, instructions: repair.instructions, rationale: repair.rationale,
                owner_issue_number: repair.github_issue_number, owner_pr_number: repair.github_pr_number,
                finding_keys: repair.finding_identities, observations: repair.findings.map(&:observation) }
            end).call
          assessment.fetch("repairs").each { |plan| assign_plan(plan) }
          assessed_keys = assessment.fetch("assessed_finding_keys")
          record_assessment(assessment, observed)
          @plans.concat(assessment.fetch("deferred").map { |entry| entry.merge("action" => "defer") })
        rescue PlanRepairs::InvalidAssessment, AgentHarness::Error => error
          planning_error = error.is_a?(PlanRepairs::InvalidAssessment) ? error.reason : error.class.name
          Rails.logger.warn(message: "pghero_overview.assessment_deferred", project_id: @project.id,
            error_class: error.class.name, reason: planning_error)
        end
        findings_scope.find_each do |row|
          next if observed.key?("#{row.database}/#{row.finding_key}") || row.resolved_at.present?
          next unless collected_categories.include?(Policy.category_for(row.finding_type.to_sym))

          row.update!(resolved_at: @now.call)
        end
        repairs_scope.includes(:findings).find_each { |repair| maintain_repair(repair) }
        deferred = actionable_findings.filter_map do |finding|
          row = rows.fetch(finding.key).reload
          finding.key unless row.repair && (row.repair.github_issue_number || row.repair.github_pr_number)
        end
        Result.new(**@counts, deferred: deferred.size, deferred_keys: deferred,
          planning_error: planning_error, repair_plans: @plans, assessed_keys: assessed_keys)
      end

      private

      # @spec RAILS-CONTROL-PLANE-036
      def record_assessment(assessment, observed)
        selected = assessment.fetch("assessed_finding_keys").to_set
        entries = assessment.fetch("repairs").map do |plan|
          [ plan.fetch("finding_keys"), "covered_by_repair", plan.fetch("rationale"), plan.fetch("evidence") ]
        end
        entries.concat(assessment.fetch("deferred").map do |entry|
          [ entry.fetch("finding_keys"), "deferred", entry.fetch("reason"), nil ]
        end)
        entries.each do |keys, disposition, reason, evidence|
          keys.each do |identity|
            next unless selected.include?(identity)

            finding = observed.fetch(identity)
            row = findings_scope.find_by!(database: finding.database, finding_key: finding.key)
            row.update!(assessment: { disposition: disposition, reason: reason, evidence: evidence,
              fingerprint: finding.fingerprint, assessed_at: @now.call.utc.iso8601(6) })
          end
        end
      end

      def repairs_scope
        PgHeroOverviewRepair.where(project: @project)
      end

      def recover_owners
        unpublished = repairs_scope.where(github_issue_number: nil, github_pr_number: nil)
        recoverable = findings_scope.where(repair_id: nil)
          .or(findings_scope.where(repair_id: unpublished.select(:id)))
        recoverable.includes(:repair).find_each do |row|
          identity = "#{row.database}/#{row.finding_key}"
          candidates = @snapshot.records.reject { |record| @snapshot.pull_request?(record) }
            .select { |record| @snapshot.finding_keys(record).include?(identity) }
          local_repair = row.repair
          if local_repair
            candidates.select! { |record| @snapshot.repair_key(record) == local_repair.repair_key }
          end
          owner = candidates.find { |record| record.number.to_i == row.github_issue_number } ||
            candidates.min_by { |record| [ record.state == "open" ? 0 : 1, record.number.to_i ] }
          owner ||= @snapshot.issue(row.github_issue_number) if row.github_issue_number && local_repair.nil?
          next unless owner

          repair = repairs_scope.find_by(database: row.database, github_issue_number: owner.number) || local_repair ||
            repairs_scope.find_by(database: row.database, repair_key: @snapshot.repair_key(owner))
          repair ||= repairs_scope.new(database: row.database,
            repair_key: @snapshot.repair_key(owner).presence || "issue/#{owner.number}",
            title: owner.title.to_s.presence || "PgHero repair ##{owner.number}",
            instructions: "Investigate the evidence and verify the existing repair.",
            rationale: "Recovered existing finding ownership.")
          if repair.github_issue_number.nil?
            repair.assign_attributes(github_issue_number: owner.number,
              managed_issue: @snapshot.managed_issue?(owner))
          end
          repair.save! if repair.changed? || repair.new_record?
          row.update!(repair: repair, github_issue_number: row.github_issue_number || owner.number)
        end
      end

      def import_pr_coverage
        @snapshot.records.select { |record| @snapshot.pull_request?(record) && record.state == "open" }.each do |pr|
          sources = repairs_scope.where(github_issue_number: @snapshot.closing_numbers(pr)).order(:github_issue_number).to_a
          explicit_rows = findings_scope.where(repair_id: nil).select do |row|
            @snapshot.finding_keys(pr).include?("#{row.database}/#{row.finding_key}")
          end
          (sources.map(&:database) + explicit_rows.map(&:database)).uniq.each do |database|
            same_database = sources.select { |repair| repair.database == database }
            canonical = same_database.first || repairs_scope.find_or_create_by!(database: database, repair_key: "pr/#{pr.number}") do |repair|
              repair.title = pr.title
              repair.instructions = "Verify the repair declared in PR ##{pr.number}."
              repair.rationale = "Existing PR explicitly declares coverage."
              repair.github_pr_number = pr.number
              repair.managed_issue = false
            end
            if same_database.many?
              canonical.assign_attributes(
                instructions: same_database.map(&:instructions).uniq.join("\n\n"),
                rationale: same_database.map(&:rationale).uniq.join("\n\n"))
            end
            canonical.update!(github_pr_number: pr.number)
            same_database.drop(1).each do |alias_repair|
              alias_repair.findings.each { |row| row.update!(repair: canonical) }
              alias_repair.findings.reset
              alias_repair.destroy!
            end
            explicit_rows.select { |row| row.database == database }.each { |row| row.update!(repair: canonical) }
          end
        end
      end

      def assign_plan(plan)
        member_rows = plan.fetch("finding_keys").map do |identity|
          database, key = identity.split("/", 2)
          findings_scope.find_by!(database: database, finding_key: key)
        end
        issue, pr = plan.values_at("owner_issue_number", "owner_pr_number")
        key = if issue
          "issue/#{issue}"
        elsif pr
          "pr/#{pr}"
        else
          "assessment/#{Digest::SHA256.hexdigest(plan.fetch('finding_keys').sort.join('|'))}"
        end
        existing_owner = if issue
          repairs_scope.find_by(database: member_rows.first.database, github_issue_number: issue)
        elsif pr
          repairs_scope.find_by(database: member_rows.first.database, github_pr_number: pr)
        end
        repair = existing_owner || repairs_scope.find_or_initialize_by(database: member_rows.first.database, repair_key: key)
        if repair.new_record?
          repair.assign_attributes(title: plan.fetch("title").truncate(255), instructions: plan.fetch("instructions"),
            rationale: plan.fetch("rationale"), github_issue_number: issue, github_pr_number: pr,
            managed_issue: issue.nil? && pr.nil?)
          repair.managed_issue = @snapshot.managed_issue?(@snapshot.issue(issue)) if issue
          repair.save!
        end
        member_rows.each { |row| row.update!(repair: repair, github_issue_number: row.github_issue_number || issue) }
        @plans << plan.merge("action" => issue || pr ? "reuse" : "create")
      end

      def maintain_repair(repair)
        members = repair.findings.to_a
        return if members.empty?

        active = members.any? { |row| row.resolved_at.nil? }
        if !repair.managed_issue
          repair.update!(resolved_at: active ? nil : (repair.resolved_at || @now.call))
          return
        end
        if repair.github_issue_number.nil?
          actionable = members.any? { |row| @actionable_identities.include?("#{row.database}/#{row.finding_key}") }
          return unless active && actionable && @counts[:created] < @cap

          body = repair_body(repair, members)
          number = if @dry_run
            -(@counts[:created] + 1)
          else
            @client.create_issue(@project.full_name, title: "[pghero] #{repair.title}".truncate(255),
              body: body, labels: issue_labels).number
          end
          repair.update!(github_issue_number: number, issue_last_updated_at: @now.call)
          members.each { |row| row.update!(github_issue_number: number) if row.github_issue_number.nil? }
          @counts[:created] += 1
          return
        end
        issue = @snapshot.issue(repair.github_issue_number)
        # Missing or newly untrusted work is not evidence of a closed issue.
        return unless issue

        if !active
          if issue.state == "open"
            write_issue(issue.number, state: "closed")
            @client.add_comment(@project.full_name, issue.number,
              "Covered findings no longer observed; last observed #{members.map(&:last_seen_at).max.utc.iso8601}.") unless @dry_run
            @counts[:closed] += 1
          end
          repair.update!(resolved_at: repair.resolved_at || @now.call)
        elsif issue.state != "open"
          return unless members.any? { |row| @actionable_identities.include?("#{row.database}/#{row.finding_key}") }
          write_issue(issue.number, state: "open", body: refreshed_body(repair, members, issue))
          repair.update!(resolved_at: nil, issue_last_updated_at: @now.call)
          @client.add_comment(@project.full_name, issue.number, "Covered finding observed again; reopening.") unless @dry_run
          @counts[:reopened] += 1
        else
          marker = "<!-- pghero-overview-repair:"
          imported = !issue.body.to_s.include?(marker)
          covered = @snapshot.finding_keys(issue)
          return if imported && members.all? { |row| covered.include?("#{row.database}/#{row.finding_key}") }

          body = refreshed_body(repair, members, issue)
          observation_time = /^\*\*Observed at:\*\* .*$/
          return if issue.body.to_s.gsub(observation_time, "") == body.gsub(observation_time, "")

          write_issue(issue.number, body: body)
          repair.update!(resolved_at: nil, issue_last_updated_at: @now.call)
          @counts[:updated] += 1
        end
      end

      def refreshed_body(repair, members, issue)
        original = issue.body.to_s.split("<!-- pghero-overview-repair:", 2).first.to_s.strip
        [ original.presence, repair_body(repair, members) ].compact.join("\n\n")
      end

      def write_issue(number, **attributes)
        @client.update_issue(@project.full_name, number, **attributes) unless @dry_run
      end

      def repair_body(repair, members)
        evidence = members.sort_by(&:finding_key).map do |row|
          data = row.observation.deep_symbolize_keys
          next "<!-- #{IDENTITY_MARKER}: #{row.database}/#{row.finding_key} -->\nEvidence unavailable; retain existing investigation." if data.empty?

          data[:type] = data[:type].to_sym
          data[:category] = data[:category].to_sym
          data[:observed_at] = Time.iso8601(data[:observed_at]) if data[:observed_at].is_a?(String)
          finding = Finding.new(**data)
          <<~MEMBER
            <!-- #{IDENTITY_MARKER}: #{finding.identity} -->
            <!-- #{FINGERPRINT_MARKER}: #{finding.fingerprint} -->
            ### #{finding.title}
            **Finding type:** #{finding.type}
            **Observed at:** #{finding.observed_at.utc.iso8601}
            Status: #{row.resolved_at ? 'no longer observed' : 'observed; incomplete categories retain previous evidence'}
            #{observed_sections(finding)}
          MEMBER
        end.join("\n")
        <<~BODY.strip
          <!-- pghero-overview-repair: #{repair.repair_key} -->
          Development PgHero repair investigation lead. Validate with measurements before changing the schema.

          ## Proposed repair
          #{repair.instructions}

          ## Coverage rationale
          #{repair.rationale}

          **Database:** #{repair.database}
          **Dashboard:** #{@dashboard_base_url}/pghero?database=#{repair.database}

          ## Covered observations
          #{evidence}

          This issue closes only when every covered observation disappears from a successfully collected category.
        BODY
      end

      def issue_labels
        [ LABEL, @project.generated_label_name, @project.automation_label_name ].compact.uniq
      end

      def findings_scope
        PgHeroOverviewFinding.where(project: @project)
      end

      def observed_sections(finding)
        finding.observed.reject { |key, _| key.to_s.start_with?("threshold") }.map do |key, value|
          render_observed(key, value, threshold_for(key, finding.observed))
        end.join("\n")
      end

      def render_observed(key, value, threshold)
        if value.is_a?(Array)
          lines = [ "- #{key}:" ]
          value.each { |item| lines << "  - #{render_value(item)}" }
          lines.join("\n")
        elsif threshold
          "- #{key}: #{render_value(value)} (threshold: #{render_value(threshold)})"
        else
          "- #{key}: #{render_value(value)}"
        end
      end

      def render_value(value)
        return value.inspect unless value.is_a?(String)
        return value if value.length <= 80 && !value.include?("\n")

        "\n  ```sql\n  #{value.truncate(BODY_TEXT_LIMIT).gsub("\n", "\n  ")}\n  ```"
      end

      # Joins a value with its sibling threshold key when one exists
      # (calls -> threshold_calls, average_ms -> threshold_ms,
      # total_connections -> threshold).
      def threshold_for(key, observed)
        unit = %w[_ms _calls _pct _bytes _sec _seconds].find do |suffix|
          key.to_s.end_with?(suffix) && key.to_s.length > suffix.length
        end
        candidates = [ :"threshold_#{key}" ]
        candidates << :"threshold#{unit}" if unit
        candidates << :threshold
        candidates.each do |candidate|
          value = observed[candidate]
          return value unless value.nil?
        end
        nil
      end
    end
  end
end
