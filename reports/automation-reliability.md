# Automatic refresh reliability

## Confirmed incident evidence (2026-08-31)

- Run 33256180945 (August 29): API and validation succeeded without a data change;
  production verification was skipped, so the workflow became green without checking the live site.
- Runs 33276814950, 33283472706, 33298773461 and 33315381972: GitHub data push
  succeeded, but the production file stayed old for the full verification window.
- The existing Netlify repository webhook was active and returned HTTP 204 for these push deliveries.
  That proves receipt, not a published production deployment. Netlify's internal build/approval state
  was not accessible with the existing GitHub credential.
- Run 33337206020: the first API page (region 11110 / month 202603 / page 1)
  failed to connect after five attempts. This does not distinguish an upstream outage,
  a route failure or a source-side runner/IP restriction. It was not an API-key rejection.
- Previous transport used one 40-second request timeout, retried authentication failures,
  and delayed retries by 3/10/20/20 seconds. Job timeout was 90 minutes and concurrency already serialized updates.

## Stages and safety

1. Collect into an isolated candidate. Separate 25-second connection and 60-second response deadlines;
   six total attempts with 5/15/30/60/120-second backoff. HTTP 401/403 and ServiceKey errors fail immediately.
   Any required or discovery request failure aborts the entire update, leaving the tracked file unchanged.
2. Validate the complete dataset and first-seen invariants, then fetch main again before staging/pushing.
   Never force push. A concurrent edit to data, collection code or generated reports aborts publication.
   A real data difference is required for a data commit.
3. Independently examine production and request deployment-only recovery when necessary.
4. Fetch production build metadata and the actual transactions and supply-mapping files.
   Validate Git SHA, metadata, dataset contents and normalized SHA-256 hashes.
   Recheck main after verification to avoid approving an outdated target.

The 261-entry catalog currently includes the original 136 complexes. No existing complex or transaction
is removed by this infrastructure change. Existing first_seen_at, tracking keys, transaction IDs,
cancellations and supply mappings keep their established matching semantics.
New zero-history complexes may remain explicitly deferred when all queries succeeded but identification
is ambiguous; a failed query is no longer treated as a harmless deferred lookup.

## Deployment

Netlify's build command generates public/data/build-meta.json using COMMIT_REF, DEPLOY_ID and CONTEXT.
This file is deliberately gitignored: a tracked file cannot contain the hash of the commit that includes itself.
The metadata contains the source commit, dataset generation/refresh times, latest contract date, counts,
file hashes and production deploy ID. No API keys or private machine paths are published.

Every execution checks production, including failed API runs, zero-change runs and same-day collection reuse.
The final workflow remains failed if collection/data/Git failed even when the previous valid dataset is
successfully deployed. Deployment-only manual mode explicitly reports that API collection was not performed.

Existing NETLIFY_BUILD_HOOK or NETLIFY_AUTH_TOKEN credentials, when available, authorize up to two deployment-only
recovery requests. They are optional for normal Git-triggered deployment, never printed, and never committed.
Without an authorized recovery channel, a stale site is reported as FAILED, not silently accepted.
A provider build stopped/locked/pending approval cannot be repaired by falsifying author identity or bypassing approval.

## Receipts and recovery

Sanitized pipeline-diagnostics artifacts contain report.json, api-log.json and expected-meta.json for 14 days.
No raw data, backup or credentials are uploaded. A same-day successful collection can be reused only if its
receipt's collector version/fingerprint and committed data hash match current main. This also permits deployment
recovery after a prior workflow failed at Netlify, without querying the API again.

Scheduled runs and the manual default use refresh, so later scheduled runs still collect newly reported trades.
Manual modes: auto (explicit verified same-day reuse), refresh (force a real collection), deploy-only (no API calls).
Schedules remain 06:37, 09:23, 12:41, 16:07, 19:29 and 22:53 Asia/Seoul. The shared concurrency group prevents
overlap with older executions. The job has a 90-minute ceiling.

## Tests

- test-update-pipeline.cjs: A/B/C/E/F/G/H, unconditional production verification, explicit deployment-only mode.
- test-molit-retries.ps1: D/E/H, timeout/reset/429/5xx retries, exact backoff, authentication fail-fast, redaction.
- test-molit-transport.ps1: real socket body-read timeout.
- test-openapi-updater.ps1: real HTTP 503 recovery, matching, cancellation, duplicate distinction and probe preservation.
- test-deferred-catalog-matching.ps1, with and without -FailDiscovery: safe deferral versus partial-collection hard failure.
- Existing first-seen, weekly-new, historical tracking, catalog and supply mapping regression suites remain active.

## Real GitHub run (2026-08-31)

Run 33344865874 completed with FAILED, correctly separating the successful data update from stale production.

- API: 246/246 region-month pairs, 247 HTTP attempts. Region 26470 / 202607 / page 1 timed out once,
  waited five seconds and then recovered. API authentication was recognized.
- Matching: 236 matched + 25 existing deferred zero-history catalog entries = 261 requested;
  no critical unmatched complex and no failed request.
- Records: 66,310 -> 66,311; new 1, removed/cancelled 0, corrected 36; latest contract 2026-08-28.
- Candidate validation and GitHub push succeeded; data commit 25cc64dfd22d11615211846e13044fb711cb8fbc.
- The production step performed all 31 checks and two deployment-only recovery attempts without re-collecting.
  Recovery requests could not be authorized because no existing Netlify recovery credential was available.
- Netlify's webhook accepted the data push with HTTP 204. Production still served 2026-08-27 data,
  latest contract 2026-08-24, 63,747 records; build-meta.json returned 404.
  The internal Netlify build failure reason and published commit cannot be determined from those facts alone.
- API, validation and Git stages passed; deployment and live-site verification failed. Execution took 1,195 seconds.
  The GitHub run's regression suite passed; the fresh 66,311-record dataset passed the existing local regression
  suites again. A subsequent strict-final-gate test also rejects missing/skipped/cancelled regressions.

The repository cannot grant itself Netlify administrator authority. The remaining production recovery requires
an authorized connection to the existing Netlify site; changing the MOLIT API key will not repair this failure.
