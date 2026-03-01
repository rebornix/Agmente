# Scenario Front Matter

Use this front matter at the top of every `e2e/scenarios/*.md` file.

## Required Keys
- `name`: stable scenario identifier
- `protocol`: `acp` or `codex`
- `target`: `ios-simulator`, `manual`, or another documented target

## Optional Keys
- `backend`: single backend id from `e2e/backends/`
- `backends`: list of backend ids when one scenario supports a matrix
- `tags`: short search/filter labels
- `owners`: GitHub handles or team names
- `requires`: notable prerequisites such as minimum CLI versions or permissions

## Example

```md
---
name: acp-custom-cwd
protocol: acp
backend: copilot-acp
target: ios-simulator
tags: [acp, cwd, regression]
requires:
  - copilot >= 0.0.420
  - port 8765 free
---
```

## Required Body Sections
- `# Setup`
- `# Steps`
- `# Assertions`
- `# Cleanup`

## Optional Body Sections
- `# Failure Insights`
- `# Checkpoints`
- `# Wire Assertions`
