# Sourced by morph.sh and reactive.sh: sets DIR to a cache holding jsdom, installing it on first use
# (needs a network once).
DIR=${GWEB_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/goose-web-test}
if [ ! -d "$DIR/node_modules/jsdom" ]; then
  mkdir -p "$DIR"
  npm install --prefix "$DIR" --no-save --no-audit --no-fund jsdom@31.0.0 >&2
fi
