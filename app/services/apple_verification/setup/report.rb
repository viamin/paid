# frozen_string_literal: true

module AppleVerification
  module Setup
    # Renders a preflight + smoke Markdown report. The rendered plan and
    # operator action list match the canonical Markdown operator guide so
    # there is no independently maintained duplicate guide.
    # @spec APPLE-SETUP-005
    class Report
      def self.call(...)
        new(...).render
      end

      def initialize(preflight: nil, plan: nil, smoke: nil,
        guide_path: "docs/rdrs/apple-worker-operator-guide.md",
        generated_at: Time.current)
        @preflight = preflight
        @plan = plan
        @smoke = smoke
        @guide_path = guide_path
        @generated_at = generated_at
      end

      def render
        lines = [ "# Apple worker setup report", "" ]
        lines << "Generated at: `#{generated_at.iso8601}`"
        lines << ""
        lines.concat(preflight_section)
        lines.concat(smoke_section) if smoke
        lines.concat(plan_section) if plan && !plan.empty?
        lines << ""
        lines << "The canonical operator guide at `#{guide_path}` covers every action listed here. Run `bin/apple-worker-setup --plan` to regenerate this section from the latest preflight."
        lines.join("\n")
      end

      private

      attr_reader :preflight, :plan, :smoke, :guide_path, :generated_at

      def preflight_section
        return [ "## Preflight", "", "_no preflight run supplied_", "" ] if preflight.nil?

        rows = preflight.results.map do |result|
          "| `#{result.id}` | `#{result.status}` | #{result.detail} | #{result.fix || '—'} |"
        end
        [
          "## Preflight",
          "",
          "Status: **`#{preflight.status}`**",
          "",
          "| Check | Status | Detail | Fix |",
          "|-------|--------|--------|-----|",
          *rows,
          ""
        ]
      end

      def smoke_section
        rows = smoke.results.map do |result|
          "| `#{result.scenario_id}` | `#{result.status}` | #{result.detail} |"
        end
        [
          "## Smoke tests",
          "",
          "Satisfied: #{smoke.passed_count} passed · #{smoke.failed_count} failed · #{smoke.gap_count} gap",
          "",
          "| Scenario | Status | Detail |",
          "|----------|--------|--------|",
          *rows,
          ""
        ]
      end

      def plan_section
        return [ "## Operator action plan", "", "_no gaps to remediate_", "" ] if plan.empty?

        lines = [ "## Operator action plan", "" ]
        plan.each do |action|
          lines << "### #{action[:index]}. #{action[:title]}"
          lines << ""
          lines << "Preflight observed: `#{action[:detail]}`."
          lines << ""
          lines << "Commands:"
          lines << "```bash"
          action[:commands].each { |command| lines << command }
          lines << "```"
          lines << ""
          lines << "Expected proof: #{action[:proof]}."
          lines << ""
          lines << "See `#{guide_path}##{action[:guide_section]}` for full context."
          lines << ""
        end
        lines
      end
    end
  end
end
