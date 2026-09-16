# wp-static-gen

Fast static site generator for wp.dash.org → crash.dash.org / www.dash.org.

Replaces Simply Static's ~3 hour generation with a **~4 minute** parallel pipeline.

## What it does

1. **URL Discovery** (~27s) — Uses WP-CLI to generate all page URLs with correct WPML translations via a single batched query
2. **Parallel Fetch** (~3m) — Fetches all pages with 8 parallel wget workers through nginx basic auth
3. **Asset Copy** (~1s) — Copies theme/plugin assets directly from disk (no HTTP overhead)
4. **URL Rewriting** (~1s) — Rewrites `wp.dash.org` → target host, redirects `/wp-content/uploads/` to `media.dash.org` CDN
5. **Cleanup** — Removes empty files from 404'd URLs

## Performance

| Metric | Simply Static | wp-static-gen |
|--------|--------------|---------------|
| Time | ~2h 50m | ~4 min |
| Memory | 670MB+ | ~50MB (wget) |
| Pages | 39,866 (incl. junk) | 3,259 (actual content) |

## Usage

```bash
# Generate to crash.dash.org (default)
ssh root@wp.dash.org '/root/fast-static-gen.sh'

# Generate to www.dash.org
ssh root@wp.dash.org '/root/fast-static-gen.sh www.dash.org'
```

## Files on the server

- `/root/fast-static-gen.sh` — The generation script
- `/var/www/crash/` — Output directory (crash.dash.org)
- `/var/www/prod/` — Production output directory (www.dash.org)
- `/root/backups/` — DB + file backups
- `/var/www/wordpress/wp-content/mu-plugins/ss-optimizations.php` — SS batch size tweaks (if using SS)
- `/var/www/wordpress/wp-content/mu-plugins/ss-fast-multilingual.php` — Fast WPML URL discovery hook (if using SS)

## Prerequisites

- `wp-cli` installed on the server
- Basic auth credentials for wp.dash.org
- AWS CLI configured for S3 sync to media.dash.org
- WPML active with translations

## Why Simply Static was slow

1. **Multilingual crawler** — Made N×L individual `icl_object_id()` + `get_permalink()` calls (89K DB lookups for 21 languages × 4K posts). Took 25-30 min alone.
2. **Plugin file crawling** — `additional_files` included `/wp-content/plugins/` (19,808 PHP source files). Zero value for a static site.
3. **Upload crawling** — 14,500+ upload files fetched via HTTP even though they're on S3/media.dash.org.
4. **Single-threaded** — SS fetches one page at a time. This script uses 8 parallel workers.
5. **Batch size** — SS default batch of 50 pages per loop iteration.

## S3 Media Offload

All WordPress uploads are synced to S3 (`media.dash.org` bucket) and the WP Offload Media plugin metadata is set so WordPress generates `media.dash.org` URLs. The static generator rewrites any remaining local upload references to the CDN.

```bash
# Sync new uploads to S3
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> AWS_DEFAULT_REGION=us-west-2 \
  aws s3 sync /var/www/wordpress/wp-content/uploads/ s3://media.dash.org/wp-content/uploads/ \
  --exclude "simply-static/*" --exclude "*.php"
```

## Static overrides

Files under `/root/static-overrides/` on the server are copied over the generated output after every run (Step 6b) and are the canonical source for those pages. The roadmap page (`roadmap/index.html`) is hand-maintained there — it is NOT sourced from WordPress, and regeneration will not overwrite it.

`overrides/` in this repo mirrors the server directory for version control. After changing a file here, copy it to the server:

```bash
scp -r overrides/. root@wp.dash.org:/root/static-overrides/
```

## Known issues

- Some WPML flag images are stored in `/wp-content/uploads/flags/` outside the media library — the script copies these locally
- Tag/category archive pages may 404 if the theme doesn't support them — empty files are cleaned up automatically
- Hindi (`hi`) translations exist in WPML but are incomplete — these generate empty pages
