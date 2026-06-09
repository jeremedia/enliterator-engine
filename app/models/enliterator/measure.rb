module Enliterator
  # A weighted-signal quality score for a record (HSDL RecordQuality pattern).
  # One row per [tendable, name]; recomputed by Enliterator::Measures.recompute!.
  class Measure < ApplicationRecord
    belongs_to :tendable, polymorphic: true

    validates :name, presence: true
  end
end
