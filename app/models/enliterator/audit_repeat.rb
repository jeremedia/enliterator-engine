# frozen_string_literal: true

module Enliterator
  # v0.88: one re-examination of an already-audited claim (see the migration).
  # Measures the INSTRUMENT: does the examiner, asked again under the same
  # configuration about the same unchanged source, give the same verdict?
  class AuditRepeat < ApplicationRecord
    self.table_name = "enliterator_audit_repeats"

    belongs_to :audit, class_name: "Enliterator::Audit"
    belongs_to :heartbeat, class_name: "Enliterator::Heartbeat", optional: true

    # Fewer repeats than this in a facet ⇒ the agreement rate is reported but
    # flagged insufficient (the accuracy n-floor's sibling).
    MIN_REPEATS = 20

    class << self
      # Re-examine up to +n+ audited claims and record whether the examiner
      # agrees with itself. A candidate is the LATEST examiner audit on its
      # claim, rendered by the same tier and under the same evidence mode as
      # now, whose claim's source is byte-identical to what that audit read
      # (digest match) — so a disagreement is the instrument, not the terrain.
      # Returns { examined:, agreed:, skipped_changed_source: }.
      def run!(n, heartbeat: nil, examiner: Enliterator::Audit::Examiner.new)
        mode    = Enliterator.configuration.audit_evidence.present?
        tier    = examiner.send(:effective_tier).to_s
        ceiling = Enliterator.configuration.audit_source_chars.to_i
        stats   = { examined: 0, agreed: 0, skipped_changed_source: 0 }
        return stats if n.to_i <= 0

        scope = Enliterator::Audit.where(source: "examiner").where("auditor LIKE ?", "#{tier}:%")
        if Enliterator::Audit.column_names.include?("evidence_found")
          scope = mode ? scope.where.not(evidence_found: nil) : scope.where(evidence_found: nil)
        elsif mode
          return stats
        end

        scope.order(Arel.sql("random()")).limit(n.to_i * 4).includes(claim: :visit).each do |audit|
          break if stats[:examined] >= n.to_i
          claim = audit.claim
          next if claim.nil? || claim.visit.nil? || claim.tendable.nil?
          next if Enliterator::Audit.where(claim_id: claim.id, source: "examiner")
                                    .where("created_at > ?", audit.created_at).exists?

          full = claim.tendable.enliterator_text(facet: claim.visit.facet).to_s
          if audit.source_digest.blank? || Digest::MD5.hexdigest(full) != audit.source_digest
            stats[:skipped_changed_source] += 1
            next
          end

          r = examiner.verdict_for(facet: claim.visit.facet, key: claim.key, value: claim.value,
                                   source: full[0, ceiling], context: claim.context,
                                   truncated: full.length > ceiling)
          next unless r.is_a?(Hash)

          agrees = r[:verdict] == audit.verdict
          create!(audit: audit, heartbeat: heartbeat, facet: claim.visit.facet, verdict: r[:verdict],
                  agrees: agrees, evidence_mode: mode, auditor: "#{r[:tier]}:#{r[:model]}")
          stats[:examined] += 1
          stats[:agreed]   += 1 if agrees
        end
        stats
      end

      # { facet => { repeats:, agreed:, rate:, insufficient: } }, newest
      # configuration only: repeats under the evidence requirement and without
      # it are different instruments and never pooled.
      def agreement(evidence_mode: Enliterator.configuration.audit_evidence.present?)
        where(evidence_mode: evidence_mode).group(:facet).pluck(:facet, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN agrees THEN 1 ELSE 0 END)"))
          .sort.to_h do |facet, n, agreed|
            [ facet, { repeats: n, agreed: agreed.to_i, rate: (agreed.to_f / n).round(3), insufficient: n < MIN_REPEATS } ]
          end
      end
    end
  end
end
