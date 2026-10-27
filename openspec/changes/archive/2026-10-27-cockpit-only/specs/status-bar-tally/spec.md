## MODIFIED Requirements

### Requirement: The bar's text is also a tmux option
While a refresher keeps the cache, it SHALL set the global tmux option `@tagents_counts` to the same text as `.counts.out`, byte for byte, and only when that text changes. It SHALL unset the option when it ends and no other refresher is alive, and a list in the dashboard's pane that closes SHALL unset it when no refresher with a live process remains while a popup list SHALL NOT, so that a refresher killed with -9 does not leave the last text on the bar for good.

#### Scenario: The option follows the cache
- **WHEN** the tally changes while a refresher runs
- **THEN** `@tagents_counts` holds the new text, and the old text is not set again while the tally stays the same

#### Scenario: Taken down
- **WHEN** the last refresher ends
- **THEN** `@tagents_counts` is unset
