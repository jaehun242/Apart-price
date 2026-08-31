# Automatic refresh and GitHub Pages

## Deployment migration — 2026-08-31

The baseline was main e2d82a90c60892aaf05e6c4cd1866121fe5348e5.
That revision had two independent workflows: the data pipeline still checked Netlify,
while static.yml published public/ to GitHub Pages on pushes.
The actual schedule had six daily entries rather than 07:00 KST.

The replacement uses daily-update.yml alone:

1. Schedule: 22:00 UTC, equivalent to 07:00 Asia/Seoul the next day.
2. Normal human pushes publish current main without re-collecting; catalog configuration
   pushes preserve the existing collection behavior. Manual refresh/auto/deploy-only remain available.
3. The original Windows collection, candidate validation, tracking preservation and Git storage stages remain.
4. After successful storage, even with no data change, the same job validates committed public/ and generates metadata.
5. Official configure-pages@v5, upload-pages-artifact@v4 and deploy-pages@v4 publish public/ only.
   The upload action has an official Windows archive step; no Linux-only packaging workaround is used.
6. Deployment success is determined by the official Pages action, not an old provider URL.
7. One workflow-wide concurrency group serializes both collection and publication; cancel-in-progress is false.
   main is checked again immediately before publication and stale artifacts are rejected.

GITHUB_TOKEN pushes deliberately do not need to trigger a separate workflow.
The later data commit is included in the current job's uploaded artifact.
build-meta.json records HEAD as commit_sha, separately from the workflow trigger's GITHUB_SHA.
The generated metadata is ignored by Git and contains no secret.

Permissions: contents:write, pages:write, id-token:write and actions:read.
The latter preserves the verified collection-receipt reuse feature.
The only external API credential used by the workflow is secrets.MOLIT_API_KEY.

Removed: static.yml (its human-push behavior moved into the single workflow),
netlify.toml, verify-production.cjs, old provider credential references and URL polling.
The .netlify ignore entry remains solely to prevent old local connection files being committed.

## Collection and data safety retained

- Separate 25-second connection and 60-second read deadlines.
- Six attempts with 5/15/30/60/120-second backoff for transient network/429/5xx errors.
- Immediate authentication failure; secret redaction; region/month/page diagnostics.
- Isolated candidate files; incomplete discovery or collection aborts the update.
- Existing transactionId/tracking keys, first_seen_at, correction/cancellation handling,
  duplicate prevention, contract-date statistics and supply-area mappings remain unchanged.
- All existing complexes are preserved. Current catalog: 261 entries, including the original 136;
  the last collection matched 236 and explicitly deferred 25 zero-history candidates.
- Git fetch and stale-data protection before committing/pushing; no force push.
- Actual data change required for a data commit; API failure is never reported as zero new trades.
- Failed API/validation prevents Pages upload/deployment. A Pages failure after a successful data
  push keeps the validated Git data; manual deploy-only retries publication without API calls or commits.

## Validation

Existing OpenAPI, retry, transport timeout, deferred matching, first-seen, historical first-seen,
weekly-new, catalog and supply-area suites remain in use.

The Pages pipeline tests cover changed/no-change publication, failed collection and validation,
Pages failure after Git storage, deployment-only recovery, missing/cancelled action results,
required regression success, stale-main rejection, push/schedule mode selection and URL identity.
test-pages-workflow.cjs checks the single workflow, schedule, permissions, action versions/order,
public-only upload and absence of legacy deployment dependencies.
Workflow syntax and expressions are additionally checked with a YAML parser and actionlint.

## Historical incident context

The old August 29 run 33256180945 skipped site verification on no-change data.
August 30 runs could push data while the old site stayed stale.
After account authorization, provider records showed "Skipped due to account credit usage exceeded".
These are historical provider failures, not failures of the new Pages deployment path.
Run 33344865874 collected 246/246 pairs, validated 66,311 records and pushed data commit
25cc64dfd22d11615211846e13044fb711cb8fbc, but correctly failed its old-provider publication check.
