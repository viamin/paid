# frozen_string_literal: true

module ConfigurationProfiles
  # A single atomic transition of one field's value on a target record.
  #
  # This object is deliberately generic: +field+ is an opaque identifier (a
  # Symbol resolved by a field set), and +from+ / +to+ are plain values. It
  # carries no knowledge of profiles or the {::Project} model, so the same
  # abstraction can back a configuration-profile swap, a quality-gate bundle,
  # or a cost-budget preset.
  class Change < Data.define(:field, :from, :to)
    def reverser
      self.class.new(field: field, from: to, to: from)
    end

    def noop? = FieldSet.equivalent?(from, to)
  end
end
