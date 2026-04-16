# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Normalized activity record for a work item or pull request.
      # Returned by
      # {Automation::Providers::WorkItemProvider#fetch_issue_timeline}.
      #
      # - +event+ [Symbol] One of {EVENTS}. Providers SHOULD map
      #   provider-specific activities onto this set; unmappable events
      #   SHOULD use +:other+ and preserve details in +raw+.
      # - +actor_login+ [String, nil] Login of the acting user, downcased.
      # - +label_name+ [String, nil] Set only for +:labeled+/+:unlabeled+
      #   events.
      # - +created_at+ [Time]
      # - +raw+ [Hash] Provider-native payload preserved verbatim for
      #   audit/debugging. Policy code MUST NOT depend on its shape.
      class TimelineEvent < ::Data.define(
        :event,
        :actor_login,
        :label_name,
        :created_at,
        :raw
      )
        EVENTS = %i[
          labeled unlabeled commented assigned unassigned
          reopened closed merged referenced other
        ].freeze
      end
    end
  end
end
