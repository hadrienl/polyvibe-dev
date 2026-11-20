#!/bin/zsh

# Regenerates the copy of the model prices shipped with the application (#574), the one the costs
# are computed with on a first launch offline. Run before each release (docs/release-checklist.md),
# then commit the file.
#
# It reads LiteLLM's public list — the one ccusage uses — and keeps the chat models of the
# providers the agents reach, with their four prices per token. The application fetches the whole
# list itself once a day; this copy only has to be good enough until it does.
#
# Given a file, reads it instead of fetching the list.

set -euo pipefail

readonly repository_root="${0:A:h:h}"
readonly source_url="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
readonly destination="$repository_root/Packages/VibeManagerKit/Sources/VibePersistence/Resources/model-prices.json"
readonly providers='^(anthropic|openai|gemini|mistral|deepseek|xai)$'

if (( $# > 0 )); then
  list="$1"
else
  list="$(mktemp -t model-prices)"
  trap 'rm -f "$list"' EXIT
  # A plain GET of a public file: a generic User-Agent, nothing about whoever runs it.
  curl --fail --silent --show-error --location --proto "=https" --proto-redir "=https" \
    --max-time 60 --user-agent "VibeManager" \
    --output "$list" "$source_url"
fi

mkdir -p "${destination:h}"
jq --sort-keys --compact-output \
  --arg providers "$providers" \
  --arg fetchedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {
    version: 1,
    fetchedAt: $fetchedAt,
    prices: (
      with_entries(select(
        (.value | type) == "object"
        and (.value.mode == "chat" or .value.mode == "responses")
        and ((.value.input_cost_per_token | type) == "number")
        and ((.value.output_cost_per_token | type) == "number")
        and ((.value.litellm_provider // "") | test($providers))
      ))
      | map_values({
          input_cost_per_token,
          output_cost_per_token,
          cache_read_input_token_cost,
          cache_creation_input_token_cost
        } | with_entries(select(.value != null)))
    )
  }' "$list" > "$destination"

print "$(jq '.prices | length' "$destination") models written to ${destination#$repository_root/}"
