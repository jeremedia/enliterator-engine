module Enliterator
  # Quality review (v0.18) — the human anchor. The examiner renders verdicts;
  # this surface is where a person CONFIRMS, OVERRULES, or CORRECTS them. A
  # distinct librarian function from Requests' authority control, with a
  # distinct write path (Audit rows + claim supersession) — and deliberately
  # CORPUS-WIDE where Requests is context-scoped: accuracy is measured over
  # the whole catalog.
  #
  # The queue mixes ~1/3 examiner-SUPPORTED claims in with the defective ones
  # on purpose: humans overruling examiner-supported verdicts is the
  # false-supported rate — the line that bounds trust in the whole accuracy
  # headline. Without it the anchor only ever sees what the examiner already
  # doubted.
  class ReviewController < ApplicationController
    QUEUE_SIZE = 24

    def index
      @queue      = build_queue
      @accuracy   = Enliterator::Audit.accuracy
      @agreement  = Enliterator::Audit.anchor_agreement
      @corrected  = Enliterator::Audit.corrected_count
      @audited    = Enliterator::Audit.examiner.distinct.count(:claim_id)
      @reviewed   = Enliterator::Audit.human.distinct.count(:claim_id)
    end

    def verdict
      audit = Enliterator::Audit.examiner.find(params[:audit_id])
      claim = audit.claim
      note  = params[:note].presence

      case params[:decision]
      when "confirm"
        record_human!(claim, audit.verdict, note)
        redirect_to review_path, notice: "Confirmed the examiner: #{audit.verdict} — \"#{claim.key}\"."
      when "overrule"
        v = params[:verdict].to_s
        return redirect_to(review_path, alert: "Pick a verdict to overrule with.") unless Enliterator::Audit::VERDICTS.include?(v)
        record_human!(claim, v, note)
        redirect_to review_path, notice: "Overruled the examiner: #{v} — \"#{claim.key}\"."
      when "correct"
        value = params[:value].to_s
        return redirect_to(review_path, alert: "A correction needs the corrected value.") if value.blank?
        begin
          fresh = claim.tendable.correct_claim!(claim, value: value, note: note)
          v = Enliterator::Audit::VERDICTS.include?(params[:verdict].to_s) ? params[:verdict].to_s : "contradicted"
          record_human!(claim, v, note, corrected_claim: fresh)
          redirect_to review_path,
            notice: "Corrected \"#{claim.key}\" — the new claim is locked (curator anchor); future tends will not clobber it."
        rescue Enliterator::Claim::AlreadySuperseded
          redirect_to review_path,
            alert: "\"#{claim.key}\" was re-tended after examination — review its successor instead."
        end
      else
        redirect_to review_path, alert: "Unknown decision: #{params[:decision].inspect}."
      end
    end

    private

    def record_human!(claim, verdict, note, corrected_claim: nil)
      Enliterator::Audit.create!(
        claim:           claim,
        verdict:         verdict,
        source:          "human",
        auditor:         note || "curator",
        corrected_claim: corrected_claim
      )
    end

    # Latest examiner audit per claim with no human verdict yet; the mix is
    # ~1/3 supported, the rest defective/unverifiable first (largest piles of
    # doubt up top). Each entry carries `source_changed` (digest drift) and
    # `live` (a re-tended claim gets a successor note, not buttons).
    def build_queue
      reviewed_ids = Enliterator::Audit.human.select(:claim_id)
      latest = Enliterator::Audit.examiner.where.not(claim_id: reviewed_ids)
                                 .order(:created_at).includes(claim: [ :visit, :tendable, :context ])
                                 .group_by(&:claim_id).values.map(&:last)

      supported, doubted = latest.partition { |a| a.verdict == "supported" }
      take_supported = [ QUEUE_SIZE / 3, supported.size ].min
      picked = doubted.sort_by { |a| a.verdict == "unverifiable" ? 1 : 0 }.first(QUEUE_SIZE - take_supported) +
               supported.first(take_supported)

      picked.map do |audit|
        claim = audit.claim
        live  = claim.superseded_by_id.nil? && claim.status != "superseded"
        current = begin
          claim.tendable&.enliterator_text(facet: claim.visit&.facet).to_s
        rescue StandardError
          ""
        end
        {
          audit:          audit,
          claim:          claim,
          live:           live,
          source_changed: audit.source_digest.present? && current.present? &&
                          Digest::MD5.hexdigest(current) != audit.source_digest,
          snippet:        current[0, 280]
        }
      end
    end
  end
end
