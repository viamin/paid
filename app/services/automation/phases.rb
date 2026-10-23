# frozen_string_literal: true

module Automation
  # RDR-077 §1: the shared phase vocabulary. Phases classify responsibility;
  # they are not a mandatory linear workflow, but the delivery phases do have a
  # fixed order so a continuation grant can name the phases it covers.
  #
  # @spec AUTOMATION-PHASES-001
  module Phases
    DISCOVERY = "discovery"
    ISSUE_PREPARATION = "issue_preparation"
    CODING = "coding"
    MERGE = "merge"
    RELEASE_DEPLOYMENT = "release_deployment"
    OPERATIONS = "operations"

    ALL = [
      DISCOVERY,
      ISSUE_PREPARATION,
      CODING,
      MERGE,
      RELEASE_DEPLOYMENT,
      OPERATIONS
    ].freeze

    # Delivery order. Operations is deliberately absent: it is not part of the
    # delivery chain and can never be reached by a continuation grant.
    DELIVERY_CHAIN = [
      DISCOVERY,
      ISSUE_PREPARATION,
      CODING,
      MERGE,
      RELEASE_DEPLOYMENT
    ].freeze

    # The manual-start continuation menu. Endpoints stop at merge: granting
    # automation through merge must not authorize release or deployment.
    CONTINUATION_ENDPOINTS = [ ISSUE_PREPARATION, CODING, MERGE ].freeze

    # Capability -> owning phase. Every automatic entry point consults this
    # before it consults project settings or activation labels.
    CAPABILITY_PHASES = {
      "create_feature" => DISCOVERY,
      "auto_enhance" => ISSUE_PREPARATION,
      "auto_pick" => CODING,
      "auto_scan_prs" => CODING,
      "auto_scan_security" => CODING,
      "auto_fix_merge_conflicts" => CODING,
      "auto_merge" => MERGE,
      "auto_release" => RELEASE_DEPLOYMENT,
      "deployment" => RELEASE_DEPLOYMENT
    }.freeze

    LABELS = {
      DISCOVERY => "Discovery",
      ISSUE_PREPARATION => "Issue preparation",
      CODING => "Coding",
      MERGE => "Merge",
      RELEASE_DEPLOYMENT => "Release & Deployment",
      OPERATIONS => "Operations"
    }.freeze

    # Shown in project settings so an operator can see what a phase owns before
    # switching it off.
    RESPONSIBILITIES = {
      DISCOVERY => "Turn an idea into actionable intent: feature creation and intention gathering.",
      ISSUE_PREPARATION => "Prepare existing intent for implementation: analysis, enhancement, clarification, readiness.",
      CODING => "Implement work and bring its pull request to merge readiness: auto-pick, reviews, CI repair, conflicts.",
      MERGE => "Integrate a ready pull request: merge eligibility, approvals, auto-merge.",
      RELEASE_DEPLOYMENT => "Publish and deliver merged software: releases and deployments.",
      OPERATIONS => "Observe deployed software and manage operational responses. Paid platform health is unaffected."
    }.freeze

    PLATFORM = "platform"

    class << self
      def label(phase)
        LABELS.fetch(phase.to_s) { phase.to_s.titleize }
      end

      def phase?(value)
        ALL.include?(value.to_s)
      end

      def endpoint?(value)
        CONTINUATION_ENDPOINTS.include?(value.to_s)
      end

      def for_capability(capability)
        CAPABILITY_PHASES[capability.to_s]
      end

      # Phases a grant covers: the starting phase plus every later delivery
      # phase up to and including the endpoint.
      def chain(from_phase:, through:)
        start_index = DELIVERY_CHAIN.index(from_phase.to_s)
        end_index = DELIVERY_CHAIN.index(through.to_s)
        return [] if start_index.nil? || end_index.nil? || end_index < start_index

        DELIVERY_CHAIN[start_index..end_index]
      end

      # Endpoint choices applicable to work started in `phase`.
      def endpoints_for(phase)
        start_index = DELIVERY_CHAIN.index(phase.to_s)
        return [] if start_index.nil?

        CONTINUATION_ENDPOINTS.select do |endpoint|
          DELIVERY_CHAIN.index(endpoint) >= start_index
        end
      end

      def delivery?(phase)
        DELIVERY_CHAIN.include?(phase.to_s)
      end
    end
  end
end
