#!/bin/bash
set -e

# =====================================================
# Fast Static Site Generator for wp.dash.org
# Usage: ./fast-static-gen.sh [target-host]
# Default target: crash.dash.org
# =====================================================

DEST="/var/www/crash"
SITE="https://wp.dash.org"
BASIC_USER="REDACTED"
BASIC_PASS="REDACTED"
DEST_HOST="${1:-crash.dash.org}"
MEDIA_HOST="media.dash.org"
WORKERS=8
WP_DIR="/var/www/wordpress"

START=$(date +%s)
echo "=== Fast Static Site Generator ==="
echo "Target: ${DEST_HOST}"
echo "Start: $(date)"

rm -rf ${DEST}/*

echo "--- Step 1: URL discovery ---"
cd ${WP_DIR}
wp eval '
$urls = array();
$languages = apply_filters("wpml_active_languages", null);
foreach ($languages as $lang) {
    do_action("wpml_switch_language", $lang["code"]);
    $posts = get_posts(array(
        "post_type" => array("post", "page", "downloadgroup"),
        "posts_per_page" => -1,
        "post_status" => "publish",
    ));
    foreach ($posts as $p) {
        $url = get_permalink($p->ID);
        if ($url && !is_wp_error($url)) $urls[] = $url;
    }
}
do_action("wpml_switch_language", "en");
$cats = get_categories(array("hide_empty" => true));
foreach ($cats as $c) $urls[] = get_category_link($c->term_id);
$tags = get_tags(array("hide_empty" => true));
foreach ($tags as $t) $urls[] = get_tag_link($t->term_id);
foreach ($languages as $lang) {
    if ($lang["code"] !== "en") $urls[] = home_url("/" . $lang["code"] . "/");
}
$urls[] = home_url("/");
$urls[] = home_url("/sitemap_index.xml");
$urls = array_unique($urls);
file_put_contents("/tmp/all-urls.txt", implode(PHP_EOL, $urls));
echo count($urls) . " URLs" . PHP_EOL;
' --allow-root 2>/dev/null | grep "URLs"
S1=$(date +%s)
echo "URL discovery: $((S1 - START))s"

echo "--- Step 2: Parallel fetch (${WORKERS} workers) ---"
cat /tmp/all-urls.txt | xargs -P${WORKERS} -I{} bash -c '
  URL="{}"
  PATH_PART=$(echo "$URL" | sed "s|https://wp.dash.org||" | sed "s|/$|/index.html|" | sed "s|^$|/index.html|")
  if echo "$PATH_PART" | grep -q "\.xml$"; then :
  elif ! echo "$PATH_PART" | grep -q "\."; then PATH_PART="${PATH_PART}index.html"; fi
  DIR="'"${DEST}"'$(dirname "$PATH_PART")"
  mkdir -p "$DIR"
  wget -q --no-check-certificate --http-user='"${BASIC_USER}"' --http-password='"${BASIC_PASS}"' \
    -O "'"${DEST}"'${PATH_PART}" "$URL" 2>/dev/null || true
'
S2=$(date +%s)
echo "Fetch: $((S2 - S1))s"

echo "--- Step 3: Asset copy ---"
mkdir -p ${DEST}/wp-content/themes/dash-theme/
cp -r ${WP_DIR}/wp-content/themes/dash-theme/assets ${DEST}/wp-content/themes/dash-theme/
for f in advanced-custom-fields-pro/assets cookie-law-info/legacy/public \
         highlighting-code-block/build highlighting-code-block/assets \
         page-links-to/dist sitepress-multilingual-cms/res \
         sitepress-multilingual-cms/vendor/otgs \
         sitepress-multilingual-cms/templates/language-switchers \
         hcaptcha-for-forms-and-more/assets; do
  SRC="${WP_DIR}/wp-content/plugins/${f}"
  DST="${DEST}/wp-content/plugins/${f}"
  if [ -d "$SRC" ]; then mkdir -p "$DST"; cp -r "$SRC"/* "$DST"/ 2>/dev/null || true; fi
done
mkdir -p ${DEST}/wp-includes/js/jquery/
cp ${WP_DIR}/wp-includes/js/jquery/jquery.min.js ${DEST}/wp-includes/js/jquery/ 2>/dev/null || true
cp ${WP_DIR}/wp-includes/js/jquery/jquery-migrate.min.js ${DEST}/wp-includes/js/jquery/ 2>/dev/null || true
mkdir -p ${DEST}/wp-content/uploads/flags/
cp ${WP_DIR}/wp-content/uploads/flags/* ${DEST}/wp-content/uploads/flags/ 2>/dev/null || true
S3=$(date +%s)
echo "Assets: $((S3 - S2))s"

echo "--- Step 4: URL rewriting ---"
find "${DEST}" -type f \( -name "*.html" -o -name "*.css" -o -name "*.js" -o -name "*.xml" \) -print0 | \
  xargs -0 -P${WORKERS} sed -i \
    -e "s|https://wp\.dash\.org|https://${DEST_HOST}|g" \
    -e "s|http://wp\.dash\.org|https://${DEST_HOST}|g" \
    -e "s|//wp\.dash\.org|//${DEST_HOST}|g" \
    -e "s|wp\.dash\.org|${DEST_HOST}|g"
find "${DEST}" -type f -name "*.html" -print0 | \
  xargs -0 -P${WORKERS} sed -i \
    -e "s|https://${DEST_HOST}/wp-content/uploads/|https://${MEDIA_HOST}/wp-content/uploads/|g" \
    -e "s|/wp-content/uploads/flags/|https://${DEST_HOST}/wp-content/uploads/flags/|g" \
    -e "s|src=\"wp-content/|src=\"/wp-content/|g" \
    -e "s|href=\"wp-content/|href=\"/wp-content/|g"
find "${DEST}" -type f -name "*.html" -print0 | \
  xargs -0 -P${WORKERS} sed -i \
    -e "s|https://${MEDIA_HOST}/wp-content/uploads/flags/|https://${DEST_HOST}/wp-content/uploads/flags/|g"
S4=$(date +%s)
echo "Rewriting: $((S4 - S3))s"

find "${DEST}" -name "index.html" -empty -type f -delete
find "${DEST}" -type d -empty -delete

END=$(date +%s)
TOTAL=$((END - START))
echo ""
echo "=== RESULTS ==="
echo "Target: ${DEST_HOST}"
echo "URLs: $(wc -l < /tmp/all-urls.txt)"
echo "Files: $(find ${DEST} -type f | wc -l)"
echo "Size: $(du -sh ${DEST} | awk '{print $1}')"
echo "TOTAL: ${TOTAL}s ($(( TOTAL / 60 ))m $(( TOTAL % 60 ))s)"
