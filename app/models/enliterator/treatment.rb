module Enliterator
  # v0.17: a conservator's treatment proposal for one failure SIGNATURE (a
  # stable fingerprint of which condition probes failed and how). There is no
  # status machine here on purpose: the piles are LIVE — a fixed record passes
  # its next survey and leaves its pile — so resolution is MEASURED by the
  # pile count reaching zero, never asserted on this row. Rows persist as the
  # standing explanation ("pile empty since X" stays readable).
  class Treatment < ApplicationRecord
    validates :signature, presence: true, uniqueness: true
  end
end
