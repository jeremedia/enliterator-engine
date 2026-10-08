# frozen_string_literal: true

require "json"
require "digest"

module Enliterator
  # v0.89 — CARRY CURATION HOME. An enliteration moves one way (Portability:
  # export from the authoring host, full-replace import on the target). Human
  # curation filed on the TARGET — /review verdicts, corrections, retractions —
  # would die at the next import (v0.81 refuses rather than discard). This
  # carries it back to the authoring host, so the next export brings it home.
  #
  #   target:    rake enliterator:export_curation FILE=curation.json
  #   authoring: rake enliterator:import_curation FILE=curation.json          # dry run: the plan
  #              rake enliterator:import_curation FILE=curation.json APPLY=1  # write it
  #
  # A verdict re-attaches only to the SAME claim: same id with the same record,
  # key and value — or, failing the id, a claim of that record and key whose
  # value matches (ids diverge once both sides mint). A correction or
  # retraction is re-minted only if that claim is still live here; if the
  # authoring host re-tended it since, the verdict is still recorded (it was
  # true of that claim) and the correction is REPORTED for a human decision —
  # never replayed onto a successor it never saw. Nothing is guessed: every
  # row lands in exactly one outcome bucket.
  module CurationTransfer
    FORMAT = "enliterator-curation/1"

    module_function

    def export(path)
      audits = Enliterator::Audit.human.includes(:claim, :corrected_claim).order(:created_at).map do |a|
        {
          "id" => a.id, "claim_id" => a.claim_id, "verdict" => a.verdict, "rationale" => a.rationale,
          "auditor" => a.auditor, "created_at" => a.created_at.utc.iso8601(6),
          "claim" => fingerprint(a.claim),
          "correction" => correction_of(a)
        }
      end
      payload = { "format" => FORMAT, "exported_at" => Time.current.utc.iso8601, "audits" => audits }
      File.write(path, JSON.pretty_generate(payload))
      audits.size
    end

    # Returns { counts:, rows: } — rows carry one outcome each:
    #   attach            verdict re-attached (plain)
    #   attach_correction verdict re-attached + correction/retraction re-minted
    #   correction_held   verdict re-attached; the claim was re-tended here, so
    #                     the correction needs a human decision (reported)
    #   already_present   an identical human verdict is already here
    #   unmatched         no claim here matches — reported, nothing written
    def import(path, apply: false)
      payload = JSON.parse(File.read(path))
      raise ArgumentError, "not an #{FORMAT} file" unless payload["format"] == FORMAT

      rows = []
      Enliterator::Audit.transaction do
        payload["audits"].each { |a| rows << plan_and_apply(a, apply: apply) }
        raise ActiveRecord::Rollback unless apply
      end
      { counts: rows.map { |r| r[:outcome] }.tally, rows: rows }
    end

    # ---- internals ------------------------------------------------------

    def fingerprint(claim)
      return nil unless claim

      { "tendable_type" => claim.tendable_type, "tendable_id" => claim.tendable_id.to_s,
        "key" => claim.key, "value_digest" => value_digest(claim.value),
        "context_key" => claim.context&.key }
    end

    def value_digest(value) = Digest::MD5.hexdigest(JSON.generate(value))

    def correction_of(audit)
      fresh = audit.corrected_claim
      return nil unless fresh

      { "kind" => Enliterator::Claim.blank_value?(fresh.value) ? "retract" : "correct",
        "value" => fresh.value, "attributed_to" => fresh.attributed_to }
    end

    def plan_and_apply(a, apply:)
      fp    = a["claim"] || {}
      claim = match_claim(a["claim_id"], fp)
      base  = { prod_audit_id: a["id"], prod_claim_id: a["claim_id"], key: fp["key"],
                record: "#{fp['tendable_type']}/#{fp['tendable_id']}", verdict: a["verdict"] }
      return base.merge(outcome: "unmatched") unless claim

      at = Time.iso8601(a["created_at"])
      if Enliterator::Audit.human.where(claim_id: claim.id, verdict: a["verdict"])
                       .where(created_at: (at - 1)..(at + 1)).exists?
        return base.merge(outcome: "already_present", claim_id: claim.id)
      end

      corr = a["correction"]
      live = claim.superseded_by_id.nil? && claim.status != "superseded"
      outcome =
        if corr.nil? then "attach"
        elsif live then "attach_correction"
        else "correction_held"
        end
      row = base.merge(outcome: outcome, claim_id: claim.id)
      row[:held_correction] = corr if outcome == "correction_held"
      return row unless apply

      fresh = replay_correction(claim, corr) if outcome == "attach_correction"
      Enliterator::Audit.create!(claim: claim, verdict: a["verdict"], rationale: a["rationale"],
                                 source: "human", auditor: a["auditor"], corrected_claim: fresh,
                                 created_at: at, updated_at: at)
      row
    end

    # Same id and same fingerprint; else the record+key's claim whose value
    # matches (newest first). A context mismatch is not a match.
    def match_claim(id, fp)
      return nil if fp.blank?

      same = lambda do |c|
        c && c.tendable_type == fp["tendable_type"] && c.tendable_id.to_s == fp["tendable_id"] &&
          c.key == fp["key"] && value_digest(c.value) == fp["value_digest"] && c.context&.key == fp["context_key"]
      end
      by_id = Enliterator::Claim.find_by(id: id)
      return by_id if same.call(by_id)

      Enliterator::Claim.where(tendable_type: fp["tendable_type"], tendable_id: fp["tendable_id"], key: fp["key"])
                        .order(id: :desc).detect { |c| same.call(c) }
    end

    def replay_correction(claim, corr)
      note = corr["attributed_to"].to_s.delete_prefix("human").delete_prefix(":").presence
      if corr["kind"] == "retract"
        claim.tendable.adjudicate_absent!(claim, key: claim.key, context: claim.context, note: note)
      else
        claim.tendable.correct_claim!(claim, value: corr["value"], note: note)
      end
    end
  end
end
