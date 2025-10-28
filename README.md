# Commanded

Commanded is a powerful Elixir framework for building event-sourced CQRS
applications with confidence.

Commanded simplifies building event-sourced applications by managing command
dispatch, event persistence, and event processing. It provides the
infrastructure for defining aggregates, processing commands, and handling
events. Your applications gain a complete history of all changes while
maintaining a clean separation of concerns.

Developers face significant complexity when implementing event sourcing and
CQRS patterns from scratch. Commanded addresses this challenge by providing a
battle-tested foundation that ensures auditability, traceability, and temporal
query capabilities. It excels in domains where business rules are complex and
the complete history of state changes is valuable.

Commanded is ideal for teams building systems with strict audit requirements,
complex business logic, or evolving requirements. Financial services,
healthcare, logistics, and e-commerce organizations benefit from its ability to
maintain complete data history and support regulatory compliance. Developers who
value code maintainability, testability, and scalability will find Commanded's
approach particularly valuable for mission-critical applications.

## Documentation

The project is following https://diataxis.fr/ documentation framework. Check
the Explanations, API Reference, How-To's and Tutorials guides.

### Attribution

`Commanded` is based on [github.com/commanded/commanded](https://github.com/commanded/commanded).
This fork introduces new features with an independent release cycle, allowing
for thorough testing before contributing back to the original project.

**See [Fork Differences](guides/explanations/fork-differences.md) for a complete
list of changes and new features compared to the upstream repository.**
