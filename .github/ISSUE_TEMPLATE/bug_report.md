---
name: Bug Report
about: Report a bug or unexpected behavior
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of what the bug is.

## Steps to Reproduce

1. Deploy cluster with '...'
2. Run command '....'
3. Observe error '....'

## Expected Behavior

A clear description of what you expected to happen.

## Actual Behavior

A clear description of what actually happened.

## Environment

**Kubernetes:**
- Version: [e.g., v1.28.0]
- Platform: [e.g., kind, EKS, GKE, AKS, on-premise]

**Helm Chart:**
- Version: [e.g., 2.10.13]
- Values: [paste relevant values.yaml sections or "default"]

**Docker Image:**
- Repository: [e.g., patroni-citus-k8s]
- Tag: [e.g., latest, v2.10.13]

**PostgreSQL/Citus:**
- PostgreSQL version: [e.g., 16.4]
- Citus version: [e.g., from main branch]

## Logs and Output

### Pod Status
```bash
$ kubectl get pods -l cluster-name=<your-cluster>
# Paste output here
```

### Pod Logs
```bash
$ kubectl logs <pod-name>
# Paste relevant logs here
```

### Patroni Status
```bash
$ kubectl exec -it <pod-name> -- patronictl list
# Paste output here
```

### Error Messages
```
Paste any error messages here
```

## Configuration

### values.yaml (relevant sections)
```yaml
# Paste relevant parts of your values.yaml here
```

### Custom manifests
```yaml
# If using custom manifests, paste relevant sections
```

## Additional Context

Add any other context about the problem here, such as:
- When did the issue start occurring?
- Does it happen consistently or intermittently?
- Any recent changes to the cluster?
- Workarounds you've tried?

## Screenshots

If applicable, add screenshots to help explain your problem.

## Checklist

- [ ] I have searched existing issues to avoid duplicates
- [ ] I have tested with the latest version
- [ ] I have included all relevant logs and configuration
- [ ] I have provided steps to reproduce the issue
