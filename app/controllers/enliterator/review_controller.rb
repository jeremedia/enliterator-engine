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
    # v0.62: the focus view's source pane cap — bounded payload; the pane labels the cut.
    SOURCE_CAP = 200_000

    def index
      @queue      = build_queue
      @accuracy   = Enliterator::Audit.accuracy
      @agreement  = Enliterator::Audit.anchor_agreement
      @corrected  = Enliterator::Audit.corrected_count
      @audited    = Enliterator::Audit.examiner.distinct.count(:claim_id)
      @reviewed   = Enliterator::Audit.human.distinct.count(:claim_id)
    end

    def verdict
      # v0.26: agent flags are reviewable exactly like examiner verdicts —
      # confirming an agent's suspicion mints the same human audit.
      audit = Enliterator::Audit.where(source: %w[examiner agent]).find(params[:audit_id])
      claim = audit.claim
      note  = params[:note].presence
      # v0.62: focus-view threading — a verdict from the focus dialog carries
      # focus_self/focus_next; an alert reopens the SAME item, a success advances to the
      # NEXT. Rails drops nil query params, so the no-param path is byte-identical.
      stay     = review_path(focus: params[:focus_self].presence)
      advanced = review_path(focus: params[:focus_next].presence)

      case params[:decision]
      when "confirm"
        record_human!(claim, audit.verdict, note)
        redirect_to advanced, notice: "Confirmed the #{audit.source}: #{audit.verdict} — \"#{claim.key}\"."
      when "overrule"
        v = params[:verdict].to_s
        return redirect_to(stay, alert: "Pick a verdict to overrule with.") unless Enliterator::Audit::VERDICTS.include?(v)
        record_human!(claim, v, note)
        redirect_to advanced, notice: "Overruled the #{audit.source}: #{v} — \"#{claim.key}\"."
      when "correct"
        value = params[:value].to_s
        return redirect_to(stay, alert: "A correction needs the corrected value.") if value.blank?
        begin
          fresh = claim.tendable.correct_claim!(claim, value: value, note: note)
          v = Enliterator::Audit::VERDICTS.include?(params[:verdict].to_s) ? params[:verdict].to_s : "contradicted"
          record_human!(claim, v, note, corrected_claim: fresh)
          redirect_to advanced,
            notice: "Corrected \"#{claim.key}\" — the new claim is locked (curator anchor); future tends will not clobber it."
        rescue Enliterator::Claim::AlreadySuperseded
          redirect_to stay,
            alert: "\"#{claim.key}\" was re-tended after examination — review its successor instead."
        end
      else
        redirect_to stay, alert: "Unknown decision: #{params[:decision].inspect}."
      end
    end

    # v0.62: the focus view's source pane — the FULL text the claim was examined against,
    # lazily fetched per focused item (sources can be megabytes; the index carries only a
    # snippet). An unreadable source is LABELED, not silently blanked (rule 3).
    def source
      audit = Enliterator::Audit.where(source: %w[examiner agent]).find(params[:audit_id])
      claim = audit.claim
      text  = claim.tendable&.enliterator_text(facet: claim.visit&.facet).to_s
      render json: {
        label:     Enliterator::Label.one(claim.tendable, type: claim.tendable_type, id: claim.tendable_id),
        key:       claim.key,
        text:      text[0, SOURCE_CAP],
        truncated: text.length > SOURCE_CAP,
        length:    text.length
      }
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue StandardError => e
      render json: { error: "source unreadable — #{e.class}: #{e.message}" }, status: :ok
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

    # Latest examiner-or-agent audit per claim with no human verdict yet
    # (v0.26: an MCP agent's flags enter the same queue — the flag's whole
    # purpose is human eyes); the mix is ~1/3 supported, the rest
    # defective/unverifiable first (largest piles of doubt up top). Each
    # entry carries `source_changed` (digest drift) and `live` (a re-tended
    # claim gets a successor note, not buttons).
    def build_queue
      reviewed_ids = Enliterator::Audit.human.select(:claim_id)
      latest = Enliterator::Audit.where(source: %w[examiner agent]).where.not(claim_id: reviewed_ids)
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
          # v0.62: the record's human label (tendable is eager-loaded above — no N+1).
          label:          Enliterator::Label.one(claim.tendable, type: claim.tendable_type, id: claim.tendable_id),
          source_changed: audit.source_digest.present? && current.present? &&
                          Digest::MD5.hexdigest(current) != audit.source_digest,
          snippet:        current[0, 280]
        }
      end
    end
  end
end
