# Contributing to Niffler

Thank you for your interest in contributing to Niffler! This guide will help you get started with contributing to the project.

## Project Overview

Niffler is an AI-powered terminal assistant written in Nim that provides conversational interaction with AI models while supporting tool calling for file operations, command execution, and web fetching. It uses a multi-threaded architecture with NATS-based multi-agent capabilities.

## Getting Started

### Prerequisites

- Nim 2.2.6 or later
- TiDB or MySQL-compatible database
- NATS server (for multi-agent features)
- Git

### Development Setup

1. **Fork and Clone**
   ```bash
   git clone https://github.com/your-username/niffler.git
   cd niffler
   ```

2. **Install Dependencies**
   ```bash
   nimble install -y
   ```

3. **Database Setup**
   ```bash
   # Using Docker for TiDB
   docker run -d --name tidb -p 4000:4000 pingcap/tidb:latest

   # Create database
   mysql -h 127.0.0.1 -P 4000 -u root
   CREATE DATABASE niffler;
   ```

4. **Configuration**
   ```bash
   # Initialize config
   ./src/niffler init

   # Edit configuration
  ~/.niffler/config.yaml
   ```

5. **Run Tests**
   ```bash
   nimble test
   ```

## Development Workflow

### Branch Organization

- `main` - Stable, production-ready code
- `develop` - Integration branch for features
- `feature/*` - Individual feature branches
- `fix/*` - Bug fixes
- `docs/*` - Documentation updates

### Creating a Feature Branch

```bash
git checkout -b feature/your-feature-name develop
```

### Making Changes

1. **Code Style**: Follow the guidelines in [DEVELOPMENT.md](DEVELOPMENT.md)
2. **Testing**: Ensure all tests pass and add new tests as needed
3. **Documentation**: Update relevant documentation
4. **Commits**: Use clear, descriptive commit messages

## Code Contribution Guidelines

### Code Style

Follow Nim conventions and project-specific guidelines:

- Use camelCase, not snake_case
- Don't shadow the local `result` variable
- Use `##` for doc comments below proc signature
- Prefer generics over inheritance
- Use `return expression` for early exits
- Import full modules, not selected symbols
- Use `*` to export public fields

### Architecture Patterns

#### Thread Safety

All tool functions in `src/tools/` must be marked with `{.gcsafe.}`:

```nim
proc executeTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute tool operation
  {.gcsafe.}:
    try:
      # Implementation here
      result = "success"
    except Exception as e:
      result = $ %*{"error": e.msg}
```

#### Error Handling

Use standardized error responses:

```nim
proc handleError*(error: Exception, context: string): JsonNode =
  result = %*{
    "error": error.msg,
    "context": context,
    "type": error.name,
    "timestamp": epochTime()
  }
```

#### Tool Implementation

When implementing new tools:

1. **Schema Definition** (`src/tools/schemas.nim`):
   ```nim
   let newToolSchema = %*{
     "name": "new_tool",
     "description": "Tool description",
     "parameters": {
       "type": "object",
       "properties": {
         "param1": {
           "type": "string",
           "description": "Parameter description"
         }
       },
       "required": ["param1"]
     }
   }
   ```

2. **Tool Function** (`src/tools/new_tool.nim`):
   ```nim
   proc executeNewTool*(args: JsonNode): string {.gcsafe.} =
     ## Execute new tool operation
     {.gcsafe.}:
       try:
         let param1 = getArgStr(args, "param1")
         # Implementation
         return $ %*{"result": "success"}
       except Exception as e:
         return $ %*{"error": e.msg}
   ```

3. **Registration** (`src/tools/registry.nim`):
   ```nim
   tools["new_tool"] = Tool(
     name: "new_tool",
     execute: executeNewTool,
     schema: newToolSchema,
     requiresConfirmation: false
   )
   ```

### Testing

#### Unit Tests

Add tests for new functionality in `tests/`:

```nim
import unittest
import ../src/tools/new_tool

suite "New Tool Tests":
  test "valid execution":
    let args = %*{"param1": "test"}
    let result = executeNewTool(args)
    check result.contains("success")

  test "error handling":
    let args = %*{}  # Missing required param
    let result = executeNewTool(args)
    check result.contains("error")
```

#### Integration Tests

For end-to-end testing:

```nim
suite "Integration Tests":
  test "tool execution through API":
    # Test tool execution with LLM integration
    let conversation = createConversation()
    let response = processMessage(
      conversation,
      "Use new_tool with param1='test'"
    )
    check response.tool_calls.len > 0
```

## Documentation

### Code Documentation

- Document all public procedures with `##` comments
- Include parameter descriptions and return value information
- Document complex algorithms and design decisions

### User Documentation

- Update relevant files in `doc/` directory
- Include examples and use cases
- Update README.md if adding user-facing features

### Architecture Documentation

For significant changes:
- Update [ARCHITECTURE.md](ARCHITECTURE.md)
- Create ADRs (Architecture Decision Records) for major decisions
- Update sequence diagrams and flowcharts

## Pull Request Process

### Before Submitting

1. **Run Tests**: Ensure all tests pass
   ```bash
   nimble test
   ```

2. **Code Quality**: Run static analysis
   ```bash
   nim check src/
   ```

3. **Documentation**: Update relevant documentation

4. **Integration Tests**: For significant changes
   ```bash
   ./tests/run_integration_tests.sh
   ```

### PR Description Template

```markdown
## Description
Brief description of the change

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass (if applicable)
- [ ] Manual testing completed

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added/updated
```

### Review Process

1. **Automated Checks**: CI will run tests and code quality checks
2. **Code Review**: At least one maintainer review required
3. **Testing Review**: Test coverage and quality reviewed
4. **Documentation Review**: Documentation accuracy verified

## Types of Contributions

### Bug Fixes

1. Create an issue describing the bug
2. Add failing test case
3. Fix the bug
4. Ensure tests pass
5. Update documentation if needed

### New Features

1. **Discussion**: Open issue for discussion before implementation
2. **Design**: Include design decisions in PR description
3. **Implementation**: Follow architectural patterns
4. **Testing**: Comprehensive test coverage
5. **Documentation**: Update user and developer docs

### Documentation

- Fix typos and grammar
- Improve clarity and examples
- Add missing documentation
- Translate documentation (if applicable)

### Performance Improvements

1. Profile to identify bottlenecks
2. Benchmark before and after changes
3. Include performance metrics in PR
4. Document performance implications

## Development Tools

### Debugging

Enable debug mode:
```bash
./src/niffler --loglevel=DEBUG
```

Note: topics-based debugging not yet implemented. Use log levels for filtering:
```bash
./src/niffler --loglevel=INFO     # General information
./src/niffler --loglevel=WARN     # Warnings and above
./src/niffler --loglevel=ERROR    # Errors only
```

### Profiling

Use Nim's built-in profiler:
```bash
nim c --profiler:on --stacktrace:on src/niffler
./src/niffler
nimprof profile_result.txt
```

### Database Inspection

Use the database inspector:
```bash
./scripts/db_inspector.sh --help

# View conversations
./scripts/db_inspector.sh conversations

# View token usage
./scripts/db_inspector.sh tokens --last 7d
```

## Community Guidelines

### Code of Conduct

- Be respectful and inclusive
- Welcome newcomers and help them learn
- Focus on constructive feedback
- Consider the community's diverse perspectives

### Communication

- Use GitHub Issues for bug reports and feature requests
- Use GitHub Discussions for general questions
- Join our Discord/Slack for real-time conversation

### Getting Help

1. **Documentation**: Check existing documentation first
2. **Issues**: Search existing issues for similar problems
3. **Discussions**: Start a discussion for questions
4. **Maintainers**: Mention maintainainers for urgent issues

## Release Process

### Versioning

Niffler follows Semantic Versioning (SemVer):
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Release Checklist

For maintainers, release process:

1. **Version Update**: Update version in `niffler.nimble`
2. **Changelog**: Update `CHANGELOG.md`
3. **Tag**: Create and push git tag
4. **Build**: Create release artifacts
5. **Test**: Verify release artifacts
6. **Announce**: Post release announcement

## Architecture Decision Records (ADRs)

For significant architectural changes, create ADRs:

### ADR Template

```markdown
# ADR-001: Feature Name

## Status
Proposed/Accepted/Rejected/Superseded

## Context
What is the problem we're trying to solve?

## Decision
What was the decision?

## Consequences
What are the results of this decision?
```

### ADR Process

1. **Proposal**: Create ADR as a pull request
2. **Discussion**: Review with community
3. **Decision**: Accept or reject
4. **Implementation**: Implement accepted ADR
5. **Document**: Record decision and rationale

## Recognition

Contributors are recognized in:
- `AUTHORS.md` - List of all contributors
- Release notes - Significant contributions
- Commit history - Individual contributions

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](../LICENSE)).

## Getting Started Checklist

- [ ] Fork the repository
- [ ] Set up development environment
- [ ] Run existing tests
- [ ] Find a good first issue
- [ ] Create your first PR
- [ ] Join community discussions

## Resources

- [Project Documentation](../README.md)
- [Development Guide](DEVELOPMENT.md)
- [Architecture Overview](ARCHITECTURE.md)
- [API Documentation](MODELS.md)
- [Issue Tracker](https://github.com/your-org/niffler/issues)
- [Discussions](https://github.com/your-org/niffler/discussions)

Thank you for contributing to Niffler! 🚀