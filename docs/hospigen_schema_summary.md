# Hospigen Schema & Pipeline Instructions (for GPT-5)

## Canonical Schema Decisions
- **Pub/Sub schema**: `contracts/schemas/envelope.avsc`
  - `resource` stored as **stringified JSON**
  - Ensures compatibility with Pub/Sub AVRO requirements
- **BigQuery schema**: `contracts/schemas/envelope.bq.json`
  - Includes `message_id`, `publish_time`, and `subscription_name` when `--write-metadata` is enabled
  - Provenance stored as nested `RECORD`

## Changes Made
1. Removed duplicate schema files (`v2`, old `avro_envelope.json`, `bq_envelope_schema.json`).
2. Standardized filenames:
   - `envelope.avsc` (Pub/Sub Avro schema)
   - `envelope.bq.json` (BigQuery schema)
3. Topics `results.final` and `admin.policy_shock` explicitly bound to **canonical schema**.
4. BigQuery table `hospitalgen.events` recreated from canonical schema JSON.
5. View `hospitalgen.events_parsed` rebuilt with safe `PARSE_JSON(resource)` so stringified JSON fields can be queried.

## Verified Successes
- ✅ `admin.policy_shock` events now flow end-to-end into BigQuery and show up in both raw and parsed view.
- ✅ Pub/Sub schema validation enforced (`resource` string vs. object resolved).
- ✅ Bridge service returns `200 OK` and emits valid Pub/Sub envelopes.
- ✅ Debugging probes confirmed schema compliance (`results-final-probe`).
- ✅ Canonicalized `.env`, `.env_example`, `.gitignore` added to repo.

## Remaining Checkpoints
- Confirm `results.final` topic fully propagates into BigQuery with latest schema (post-fix).
- Monitor logs in `hospitalgen-bridge` service for schema rejection or formatting errors.
- Once verified, delete old schemas (`envelope_v1`, `envelope_v2`) to avoid confusion.

---

**Next Steps for GPT-5**
1. Always use `contracts/schemas/envelope.avsc` for Pub/Sub schema updates.  
2. Always use `contracts/schemas/envelope.bq.json` for BigQuery table creation.  
3. Confirm both `results.final` and `admin.policy_shock` topics bind to the **same canonical schema**.  
4. When testing, publish **via bridge** and **direct Pub/Sub** to verify schema roundtrip.  
