# frozen_string_literal: true

# Namespace for RDR-080 project delegation after settled intent: the pilot
# measurement records, the expansion guard, and the expansion pause that
# returns an affected project to `conservative` pending human review.
module ProjectDelegation
  def self.table_name_prefix = "project_delegation_"
end
