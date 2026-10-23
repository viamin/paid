# frozen_string_literal: true

module Automation
  # RDR-077 §3: every manual-start surface must explain before submission when
  # the selected endpoint is not the effective automation stopping point under
  # the current settings. The notice names the later phases project policy
  # permits and the settings responsible, and describes continuation as
  # conditional authorization rather than a guarantee.
  #
  # @spec AUTOMATION-PHASES-010 @spec AUTOMATION-PHASES-016
  class EffectivePolicyNotice
    NO_CONTINUATION_REASON = "Paid stops after the action you selected unless this project's settings permit more."

    class << self
      def call(...)
        new(...).call
      end

      # The sentence every endpoint description leads with, so surfaces that
      # list each endpoint choice (the run form's client-refresh payload)
      # cannot drift from the server-rendered summary.
      # @spec AUTOMATION-PHASES-010
      def selection_statement(endpoint)
        "You selected automation through #{Automation::Phases.label(endpoint)}."
      end
    end

    attr_reader :endpoint, :phase, :project, :selection

    def initialize(project:, phase:, endpoint:, continuation_selected: false)
      @project = project
      @phase = phase.to_s
      @endpoint = endpoint.to_s.presence || @phase
      @continuation_selected = continuation_selected
    end

    def call
      self
    end

    # True when later project automation may continue past the selected
    # endpoint, independent of the continuation checkbox.
    # @spec AUTOMATION-PHASES-010
    def continuation_permitted?
      permitted_phases.any?
    end

    def required?
      continuation_permitted?
    end

    def summary
      return NO_CONTINUATION_REASON if permitted_phases.empty?

      labels = permitted_phases.map { |later| Automation::Phases.label(later) }.to_sentence
      sources = permitted_entries.map { |entry| entry[:source] }.uniq.to_sentence

      "#{self.class.selection_statement(endpoint)} " \
        "This project's settings also permit #{labels}, so Paid may continue this work into #{labels} " \
        "once the earlier phase's conditions are satisfied. That permission comes from #{sources}. " \
        "Continuation is conditional authorization, not a guarantee of completing #{labels.downcase}."
    end

    # Summary that always names the selected endpoint, for surfaces that offer
    # every endpoint choice up front (the run form's client-refresh payload).
    # @spec AUTOMATION-PHASES-010
    def selection_summary
      return summary if permitted_phases.any?

      "#{self.class.selection_statement(endpoint)} #{NO_CONTINUATION_REASON}"
    end

    # Digest of project policy state, so user selections do not look stale but
    # a form cannot silently omit newly permitted continuation.
    # @spec AUTOMATION-PHASES-011
    def signature
      Digest::SHA256.hexdigest(settings.to_h.to_json)
    end

    def permitted_phases
      permitted_entries.map { |entry| entry[:phase] }
    end

    def to_h
      {
        phase: phase,
        endpoint: endpoint,
        continuation_selected: @continuation_selected,
        permitted_phases: permitted_phases,
        settings: permitted_entries.to_h { |entry| [ entry[:phase], entry[:source] ] },
        summary: summary,
        signature: signature
      }
    end

    private

    attr_reader :continuation_selected

    # Later phases that project policy permits on its own. The endpoint bounds
    # the grant; it does not prohibit independently enabled project automation,
    # and a through-merge grant never authorizes release or deployment.
    def permitted_entries
      @permitted_entries ||= later_phases.filter_map { |later| entry_for(later) }
    end

    def later_phases
      index = Automation::Phases::DELIVERY_CHAIN.index(endpoint)
      return [] if index.nil?

      Automation::Phases::DELIVERY_CHAIN[(index + 1)..]
    end

    def entry_for(later)
      case later
      when Automation::Phases::MERGE
        permitted_entry(later, settings.phase_enabled?(later), "this project's Merge phase setting")
      when Automation::Phases::RELEASE_DEPLOYMENT
        permitted_entry(later, release_or_deployment_enabled?, release_or_deployment_source)
      else
        permitted_entry(later, settings.phase_enabled?(later), "this project's #{Automation::Phases.label(later)} phase setting")
      end
    end

    def permitted_entry(phase, permitted, source)
      return nil unless permitted

      { phase: phase, source: source }
    end

    def release_or_deployment_enabled?
      settings.release_enabled? || settings.deployment_enabled?
    end

    def release_or_deployment_source
      if settings.release_enabled? && settings.deployment_enabled?
        "this project's release and deployment controls"
      elsif settings.release_enabled?
        "this project's release control"
      else
        "this project's deployment control"
      end
    end

    def settings
      @settings ||= PhaseSettings.call(project)
    end
  end
end
