# Contributing to Citus on Kubernetes

Thank you for your interest in contributing to Citus on Kubernetes! This document provides guidelines and instructions for contributing to this project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How to Contribute](#how-to-contribute)
- [Development Workflow](#development-workflow)
- [Coding Standards](#coding-standards)
- [Submitting Changes](#submitting-changes)
- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [Documentation](#documentation)

## Code of Conduct

This project adheres to a Code of Conduct that all contributors are expected to follow. Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## Getting Started

### Prerequisites

- Docker
- Kubernetes cluster (kind, minikube, or cloud provider)
- kubectl
- Helm 3.0+
- Basic understanding of PostgreSQL and distributed databases

### Setting Up Development Environment

1. **Fork the repository** on GitHub

2. **Clone your fork**:
   ```bash
   git clone https://github.com/YOUR_USERNAME/citus-on-k8s.git
   cd citus-on-k8s
   ```

3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/ORIGINAL_OWNER/citus-on-k8s.git
   ```

4. **Create a local Kubernetes cluster**:
   ```bash
   kind create cluster
   ```

5. **Build the Docker image**:
   ```bash
   docker build -f Dockerfile.citus -t patroni-citus-k8s:dev .
   kind load docker-image patroni-citus-k8s:dev
   ```

6. **Deploy with Helm**:
   ```bash
   helm install citus-dev ./helm/citus-cluster \
     --set image.tag=dev \
     --set image.pullPolicy=Never
   ```

## How to Contribute

### Types of Contributions

We welcome various types of contributions:

- 🐛 **Bug fixes** - Fix issues in code or documentation
- ✨ **Features** - Add new functionality or enhancements
- 📝 **Documentation** - Improve or add documentation
- 🧪 **Tests** - Add or improve test coverage
- 🔧 **Configuration** - Improve Helm charts or Kubernetes manifests
- 🎨 **Examples** - Add example configurations or use cases

## Development Workflow

### 1. Create a Branch

Always create a new branch for your work:

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/your-bug-fix
```

**Branch naming conventions**:
- `feature/` - New features or enhancements
- `fix/` - Bug fixes
- `docs/` - Documentation only changes
- `refactor/` - Code refactoring
- `test/` - Adding or updating tests

### 2. Make Your Changes

- Write clean, readable code
- Follow existing code style and conventions
- Add comments for complex logic
- Update documentation as needed
- Add or update tests where applicable

### 3. Test Your Changes

Before submitting, ensure:

```bash
# Rebuild Docker image
docker build -f Dockerfile.citus -t patroni-citus-k8s:dev .

# Test Helm chart
helm lint ./helm/citus-cluster
helm template test ./helm/citus-cluster --debug

# Deploy and test
kubectl apply -f <your-changes>
kubectl get pods -l cluster-name=citus-dev
kubectl exec -it citus-dev-0-0 -- patronictl list
```

### 4. Commit Your Changes

We use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages:

```bash
# Format:
<type>(<scope>): <subject>

<body>

<footer>
```

**Types**:
- `feat:` - New feature (triggers minor version bump)
- `fix:` - Bug fix (triggers patch version bump)
- `docs:` - Documentation changes
- `style:` - Code style changes (formatting, etc.)
- `refactor:` - Code refactoring
- `test:` - Adding or updating tests
- `chore:` - Maintenance tasks

**Examples**:
```bash
git commit -m "feat(helm): add support for custom PostgreSQL parameters"
git commit -m "fix(ssl): correct certificate path in init container"
git commit -m "docs(readme): update installation instructions"
```

**Breaking changes**:
```bash
git commit -m "feat(api): change worker registration method

BREAKING CHANGE: Worker nodes now require explicit registration via citus_add_node()"
```

### 5. Push and Create Pull Request

```bash
# Push to your fork
git push origin feature/your-feature-name

# Create Pull Request on GitHub
```

## Coding Standards

### Dockerfile

- Use multi-stage builds where appropriate
- Minimize layer count
- Pin versions for reproducibility
- Add comments explaining non-obvious steps
- Clean up apt cache to reduce image size

### Helm Charts

- Follow [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)
- Use `_helpers.tpl` for template functions
- Validate values in templates
- Include helpful comments in `values.yaml`
- Test with `helm lint` and `helm template`

### Shell Scripts

- Use `#!/bin/bash` shebang
- Enable error handling: `set -euo pipefail`
- Quote variables: `"${VAR}"`
- Use meaningful variable names
- Add comments for complex logic

### Documentation

- Use clear, concise language
- Include code examples
- Add tables of contents for long documents
- Link to related documentation
- Keep line length reasonable (80-120 characters)

## Submitting Changes

### Pull Request Guidelines

1. **Fill out the PR template** completely
2. **Reference related issues**: "Fixes #123" or "Relates to #456"
3. **Provide context**: Explain why the change is needed
4. **Include testing evidence**: Screenshots, logs, or test results
5. **Keep PRs focused**: One feature/fix per PR
6. **Update documentation**: Include doc updates in the same PR
7. **Respond to feedback**: Address review comments promptly

### PR Checklist

Before submitting your PR, ensure:

- [ ] Code follows project conventions
- [ ] Tests pass locally
- [ ] Documentation is updated
- [ ] Commit messages follow conventional commits
- [ ] No sensitive information (passwords, keys, internal URLs)
- [ ] CHANGELOG.md updated (for significant changes)
- [ ] Helm chart version bumped (if applicable)

### Review Process

1. **Automated checks** run (linting, validation)
2. **Maintainer review** (1-2 reviewers)
3. **Feedback** and requested changes
4. **Approval** from maintainers
5. **Merge** to main branch

## Reporting Bugs

### Before Submitting a Bug Report

- Check existing issues to avoid duplicates
- Test with the latest version
- Collect relevant information (logs, versions, configuration)

### Bug Report Template

Use the GitHub issue template or include:

- **Description**: Clear description of the bug
- **Steps to Reproduce**: Detailed steps to reproduce
- **Expected Behavior**: What should happen
- **Actual Behavior**: What actually happens
- **Environment**:
  - Kubernetes version
  - Helm chart version
  - Docker image version
  - Cloud provider (if applicable)
- **Logs**: Relevant pod logs, events, or error messages
- **Configuration**: Relevant `values.yaml` or manifest excerpts

## Suggesting Features

### Feature Request Template

- **Use Case**: Describe the problem or use case
- **Proposed Solution**: How you envision the feature
- **Alternatives**: Other approaches considered
- **Additional Context**: Screenshots, diagrams, examples

### Feature Development Process

1. **Discussion**: Open an issue to discuss the feature
2. **Design**: Agree on design approach with maintainers
3. **Implementation**: Develop the feature
4. **Testing**: Thoroughly test the feature
5. **Documentation**: Document usage and configuration
6. **Review**: Submit PR for review

## Documentation

### Types of Documentation

- **README.md**: Overview and quick start
- **CLAUDE.md**: Comprehensive development guide
- **docs/**: Detailed feature documentation
- **helm/citus-cluster/README.md**: Helm chart documentation
- **Code comments**: Inline documentation

### Documentation Standards

- Write in clear, simple English
- Use examples to illustrate concepts
- Include command-line examples with expected output
- Add screenshots for UI-related documentation
- Keep documentation in sync with code

### Building Documentation Locally

For testing documentation rendering:

```bash
# Install markdown preview tool
npm install -g markdown-preview

# Preview a file
markdown-preview README.md
```

## Questions and Support

- 💬 **Discussions**: Use [GitHub Discussions](https://github.com/OWNER/citus-on-k8s/discussions) for questions
- 🐛 **Issues**: Use [GitHub Issues](https://github.com/OWNER/citus-on-k8s/issues) for bugs and features
- 📖 **Documentation**: Check [docs/](docs/) for detailed guides

## License

By contributing to this project, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE)).

## Recognition

Contributors are recognized in:
- Git history and GitHub contributors page
- Release notes (for significant contributions)
- CHANGELOG.md (for notable features/fixes)

Thank you for contributing to Citus on Kubernetes! 🎉
