# frozen_string_literal: true

module Notifications
  class Rule
    include ActionView::Helpers::DateHelper
    include Rails.application.routes.url_helpers

    class << self
      # Registered rule classes that evaluate_all iterates over.
      def rule_classes
        @rule_classes ||= []
      end

      # Register a rule class so evaluate_all picks it up.
      def register(rule_class)
        rule_classes << rule_class unless rule_classes.include?(rule_class)
      end

      # Evaluate every registered rule against the given account, publishing
      # notifications for matches and auto-resolving for cleared subjects.
      def evaluate_all(account:, **kwargs)
        rule_classes.each { |rule| rule.call(scope: account, **kwargs) }
      end
    end

    def self.call(scope: nil, **kwargs)
      new.call(scope:, **kwargs)
    end

    def call(scope: nil, **_kwargs)
      matches = Array(detect(scope))

      matches.each { |subject| publish(subject) }
      resolve_unmatched(scope, matches) if auto_resolve?

      matches
    end

    private

    def auto_resolve?
      true
    end

    def publish(subject)
      Notifications::Publish.call(
        account: account_for(subject),
        source: source,
        subject: subject,
        **build(subject)
      )
    end

    def resolve_unmatched(scope, matches)
      Array(resolve_candidates(scope)).each do |subject|
        next if matched?(subject, matches)

        resolved = Notifications::Resolve.call(
          account: account_for(subject),
          source: source,
          subject: subject
        )
        clear_state(subject) if resolved
      end
    end

    def resolve_candidates(scope)
      scope
    end

    def matched?(subject, matches)
      matches.any? { |candidate| same_subject?(candidate, subject) }
    end

    def same_subject?(left, right)
      left.class == right.class && left.id == right.id
    end

    def account_for(subject)
      return subject.account if subject.respond_to?(:account)
      return subject.project.account if subject.respond_to?(:project)
      return subject.user.account if subject.respond_to?(:user)

      raise ArgumentError, "cannot infer account for #{subject.class.name}"
    end

    def state_for(subject)
      NotificationRuleState.find_or_initialize_by(
        account: account_for(subject),
        source: source,
        subject: subject
      )
    end

    def state_metadata_for(subject)
      state_for(subject).metadata.to_h.with_indifferent_access
    end

    def save_state!(subject, metadata:, first_seen_at: nil, last_seen_at: Time.current)
      state = state_for(subject)
      state.metadata = metadata
      state.first_seen_at ||= first_seen_at || last_seen_at
      state.first_seen_at = first_seen_at if first_seen_at
      state.last_seen_at = last_seen_at
      state.save!
      state
    end

    def clear_state(subject)
      state = state_for(subject)
      state.destroy! if state.persisted?
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    end

    def human_duration(since)
      return "unknown duration" unless since

      distance_of_time_in_words(since, Time.current)
    end
  end
end
