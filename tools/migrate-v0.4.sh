#!/bin/sh
# Moves an app (or any files) from goose-web v0.3 to gweb v0.4: the package is `gweb`, calls are `gweb::`, and
# submodules live in folders (web.session is gweb.auth.session). Edits the files in place; run it on a clean tree.
#
#   sh tools/migrate-v0.4.sh [DIR or FILE ...]     (default: .)
#
# Rewrites *.goose, *.html, *.gshtml and *.md. Needs perl.
set -eu
[ $# -eq 0 ] && set -- .
find "$@" -type f \( -name '*.goose' -o -name '*.html' -o -name '*.gshtml' -o -name '*.md' \) \
  -not -path '*/.gweb*' -not -path '*/.git/*' -print0 |
xargs -0 perl -pi -e '
  BEGIN {
    %d = (session=>"auth", crypto=>"auth", csrf=>"auth", rate=>"auth", cors=>"auth",
          form=>"forms", valid=>"forms", upload=>"forms",
          cache=>"http", static=>"http", stream=>"http", push=>"http",
          template=>"site", meta=>"site", sitemap=>"site", i18n=>"site", errors=>"site",
          ops=>"ops", jobs=>"ops", owner=>"ops", testing=>"");
    %f = (ops=>"log");
    $alt = join "|", sort keys %d;
  }
  s{(?<![\w.\-/])web\.($alt)\b(?!\.goose)}{ "gweb." . ($d{$1} eq "" ? "" : "$d{$1}.") . ($f{$1} // $1) }ge;
  s{import web;}{import gweb;}g;
  s{import web from }{import gweb from }g;
  s{namespace web;}{namespace gweb;}g;
  s{(?<![\w.\-/:])web::}{gweb::}g;
  s{(?<=\\n)web::}{gweb::}g;
  s{josephheinz/goose-web\@v0\.\d+\.\d+}{josephheinz/gweb\@v0.4.0}g;
  s{josephheinz/goose-(net|sqlite)\@v0\.\d+\.\d+}{josephheinz/goose-$1\@v0.4.0}g;
'
