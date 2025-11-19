# Fork Differences from Upstream

This document tracks all changes made in the `straw-hat-team/commanded` fork compared to the upstream `commanded/commanded` repository.

## Overview

This fork maintains an independent release cycle to introduce new features and improvements with thorough testing before considering contributions back to the original project.

**Upstream Repository:** [github.com/commanded/commanded](https://github.com/commanded/commanded)
**Fork Repository:** [github.com/straw-hat-team/commanded](https://github.com/straw-hat-team/commanded)

---

## Breaking Changes ❌

### **Removed Deprecated Ecto Projections "do end" Block Syntax**

**Changes:**
- Removed deprecated `project(event, do: block)` macro variant
- Removed deprecated `project(event, metadata, do: block)` macro variant
- Only function-based syntax is now supported: `project(event, fn multi -> ... end)`

### **Removed ProcessManager Support**
[PR #24](https://github.com/straw-hat-team/commanded/pull/24)

**Changes:**
- Removed all ProcessManager modules and tests
- Removed ProcessManager documentation
- Removed ProcessManager configuration
- Updated documentation to remove ProcessManager references

**Reason:** The saga pattern can be achieved using event handlers with read models and aggregates, eliminating the need for the additional ProcessManager abstraction.

### **Removed Upcasting Support**
[PR #26](https://github.com/straw-hat-team/commanded/pull/26)

**Changes:**
- Removed `Commanded.Event.Upcast` and `Commanded.Event.Upcaster` modules
- Removed upcasting from event handlers and aggregates
- Removed upcasting documentation

**Reason:** Event schema transformations can be handled explicitly in event handlers and aggregates using pattern matching, eliminating the need for a global upcasting component.

### **EnrichedMetadata Struct**
[PR #11](https://github.com/straw-hat-team/commanded/pull/11)

**Changes:**
- Replaced plain map metadata with `Commanded.EventStore.EnrichedMetadata` struct
- Updated event handlers to use struct

**Breaking:** Event handler callbacks now receive `%EnrichedMetadata{}` instead of a plain map.

## Features Added ✨

### **UUIDv7 Support**
[PR #22](https://github.com/straw-hat-team/commanded/pull/22)

**Changes:**
- Added UUIDv7 generation support for command and event IDs
- Modified command router to use `UUID.uuid7/0` by default

### **Configurable UUID Provider**

**Changes:**
- Integrated `Uniq.UUID` library for UUID generation
- Made UUID provider configurable
- Simplified UUID module by delegating to Uniq

### **Aggregate Telemetry for Version Conflicts**
[PR #8](https://github.com/straw-hat-team/commanded/pull/8)

**Changes:**
- Added telemetry events for wrong expected version errors in aggregates
- Enhanced monitoring capabilities for version conflicts

### **Custom Event ID Support**
[PR #2](https://github.com/straw-hat-team/commanded/pull/2)

**Changes:**
- Added `Commanded.Event.EventId` protocol
- Ability to set custom event IDs from event structs
- Support for deterministic event IDs

### **EventStore Adapter**
[PR #1](https://github.com/straw-hat-team/commanded/pull/1)

**Changes:**
- Bundled `Commanded.EventStore.Adapters.EventStore` directly into Commanded
- Eliminates need for separate `commanded_eventstore_adapter` package dependency

### **Ecto Projections Integration**

**Changes:**
- Integrated `Commanded.Projections.Ecto` directly into Commanded
- Added Ecto and Ecto SQL as optional dependencies
- Eliminates need for separate `:commanded_ecto_projections` package dependency
- Uses nested config format: `config :commanded, Commanded.Projections.Ecto`

**Migration from commanded_ecto_projections:**
- Update dependency to `{:commanded, "~> 2.1"}` with `{:ecto, "~> 3.11"}`
- Update config from `config :commanded_ecto_projections, repo: MyApp.Repo` to `config :commanded, Commanded.Projections.Ecto, repo: MyApp.Repo`
- No code changes required - API remains the same
