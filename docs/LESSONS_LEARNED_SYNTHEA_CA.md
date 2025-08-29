## Lessons learned — running Synthea for British Columbia (Vancouver) without US-only CSVs

Short summary
- Goal: enable Synthea to generate patients for Vancouver / British Columbia without failing on missing US-only CSV resources (for example `geography/fipscodes.csv`).
- Approach: fast, low-risk edits and short-term mitigations so generation works while preserving a clear list of longer-term hardening and data tasks.

What I changed (short list)
- Aligned packaged `synthea.properties` file to reference resource names present in the repo (removed `_ca` suffixes that pointed to missing files).
- Made `CMSStateCodeMapper` tolerant of a missing `geography/fipscodes.csv` by logging a warning and continuing with empty mappings instead of throwing during static initialization.
- Added minimal placeholder CSV files (non-destructive, short headers-only) for optional inputs that otherwise caused NPEs during initialization: `geography/fipscodes.csv`, `geography/sdoh.csv`, and `payers/insurance_eligibilities.csv`.

Files edited or added during troubleshooting
- `synthea_original/src/main/resources/synthea.properties` — updated to reference the resource filenames actually present in the repository (no `_ca` suffixes).
- `synthea_original/src/main/java/org/mitre/synthea/world/geography/CMSStateCodeMapper.java` — defensive handling for missing `geography/fipscodes.csv` (logs & empty maps vs crash).
- `src/resources/geography/fipscodes.csv` (placeholder) — header-only, to avoid resource-not-found errors.
- `src/resources/geography/sdoh.csv` (placeholder) — header-only fallback for optional SDoH data.
- `src/resources/payers/insurance_eligibilities.csv` (placeholder) — header-only fallback to avoid plan-eligibility parsing NPEs.

Why I didn't simply comment out the lines in `synthea.properties`
- Commenting might prevent a NoSuchFileException in some cases, but many parts of Synthea assume at least a stub of the data exists and perform parsing at class initialization. That can lead to other errors (NPEs) or inconsistent behavior. Changing the properties is fine if you also ensure code gracefully handles absent files. The approach taken here edits properties to point to valid resource names and hardens critical code paths, which is safer and more reproducible.

Verification performed
- Rebuilt the fat JAR (Gradle `shadowJar`) after edits.
- Verified a small run: 2 Vancouver patients generated with FHIR exporter writing JSON to a base directory (example used: `/tmp/synthea_ca_test/fhir`). The run reported: total=2, alive=2, dead=0 and produced patient and provider/practitioner JSON files.

Quick "how to reproduce" (local)
1. Build the fat JAR in `synthea_original`:

```bash
./gradlew clean shadowJar -x test
```

2. Run a quick generation (example used during testing):

```bash
java -jar build/libs/synthea-with-dependencies.jar -p 2 --exporter.fhir.export true --exporter.baseDirectory /tmp/synthea_ca_test "British Columbia" "Vancouver"
```

Recommended next steps (priority order)
1. Medium-term: harden `PlanEligibilityFinder` / `PayerManager` so a missing `payers/insurance_eligibilities.csv` is handled safely (return empty eligibility lists rather than relying on placeholder files).
2. Replace placeholder CSVs with production-quality Canadian datasets where possible (accurate equivalents for FIPS/SSA mappings and payer eligibilities) or add configuration to switch international mode where US-only CSVs are not required.
3. Add unit tests that simulate missing optional CSVs and confirm generation still initializes and exports (happy path + 1-2 edge cases).
4. Consider a smaller feature: a runtime config flag like `generate.geography.require_us_fips = true|false` to control strictness.

Edge cases and caveats
- Some export or analytics code may expect US-specific FIPS/SSA mappings; if those are required downstream, placeholders will not be sufficient for correct analytics — they only prevent crashes. Replace with real data when you need accurate downstream metrics.
- Long-term correctness for billing/payer behavior requires Canadian equivalents for plans and eligibilities.

Conclusion
- The edits and placeholders are a pragmatic, low-risk way to unblock Vancouver/BC generation quickly. The right next step is to harden the code paths that assume US-only resources and to source Canadian datasets for production-grade generation.

Status: short-term mitigations implemented and validated (2-patient test). Recommended code hardening and data replacement remain.

---
Generated and saved in `docs/LESSONS_LEARNED_SYNTHEA_CA.md`.
