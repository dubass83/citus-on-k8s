---
name: Feature Request
about: Suggest a new feature or enhancement
title: '[FEATURE] '
labels: enhancement
assignees: ''
---

## Feature Description

A clear and concise description of the feature you'd like to see.

## Problem or Use Case

Describe the problem this feature would solve or the use case it would enable.

**Example**: "I'm always frustrated when..."

## Proposed Solution

Describe how you envision this feature working.

### Configuration Example

If applicable, show how you'd like to configure this feature:

```yaml
# Example values.yaml configuration
newFeature:
  enabled: true
  option1: value1
```

### Usage Example

Show how users would interact with this feature:

```bash
# Example commands
helm install citus ./helm/citus-cluster \
  --set newFeature.enabled=true
```

## Alternatives Considered

Describe any alternative solutions or features you've considered.

## Benefits

What benefits would this feature provide?

- Benefit 1
- Benefit 2
- Benefit 3

## Potential Drawbacks

Are there any potential drawbacks or challenges with this feature?

## Additional Context

Add any other context, screenshots, diagrams, or examples about the feature request here.

### Related Features

- Link to related features or issues
- Similar features in other projects

## Implementation Ideas

If you have ideas about how to implement this, share them here (optional).

## Checklist

- [ ] I have searched existing issues and discussions to avoid duplicates
- [ ] This feature aligns with the project's goals
- [ ] I have described a clear use case
- [ ] I have considered alternatives
