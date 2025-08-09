# Swarm Script TDD Refactoring Plan

## Overview
Refactor `scripts/deployments/swarm.sh` using Test-Driven Development (TDD) following Kent Beck's Red-Green-Refactor approach and Tidy First principles.

## Testing Strategy
- Never mock third-party dependencies (docker, ssh, etc.)
- Create wrapper interfaces for external dependencies
- Test business logic separately from system integration
- Use BATS for testing following the existing pattern

## Current Issues to Address
1. **No test coverage** for swarm functionality
2. **Hard dependencies** on docker, ssh commands making testing difficult
3. **Mixed responsibilities** - business logic mixed with system calls
4. **Bug fixes needed**:
   - Line 61: Undefined `$host_ip` variable
   - Line 66: SSH user authentication TODO
   - Lines 38-41: Commented token check logic
5. **Interface clarity** - function names could be more intuitive

## TDD Test Plan (Red-Green-Refactor Cycles)

### Phase 1: Wrapper Interfaces (Tidy First - Structural Changes)
- [ ] Create `docker_wrapper.sh` interface for docker commands
- [ ] Create `ssh_wrapper.sh` interface for SSH operations
- [ ] Create `file_wrapper.sh` interface for file operations
- [ ] Update swarm.sh to use wrapper interfaces
- [ ] Verify all tests still pass (no behavior change)

### Phase 2: Core Function Tests (Red-Green-Refactor)

#### Test 1: swarm_create_ssl_secrets function
- [ ] **RED**: Write test for `swarm_create_ssl_secrets_should_create_docker_secrets_from_cert_files`
- [ ] **GREEN**: Implement minimal code to make test pass
- [ ] **REFACTOR**: Clean up implementation while keeping tests green

#### Test 2: swarm_initialize_manager function
- [ ] **RED**: Write test for `swarm_initialize_manager_should_init_swarm_with_manager_ip`
- [ ] **GREEN**: Implement minimal code to make test pass
- [ ] **REFACTOR**: Extract IP resolution logic

#### Test 3: swarm_add_worker_node function
- [ ] **RED**: Write test for `swarm_add_worker_node_should_join_node_to_swarm`
- [ ] **GREEN**: Fix undefined `$host_ip` bug and implement
- [ ] **REFACTOR**: Improve error handling

#### Test 4: swarm_sync_node_configuration function
- [ ] **RED**: Write test for `swarm_sync_should_add_missing_nodes`
- [ ] **GREEN**: Implement node addition logic
- [ ] **REFACTOR**: Extract node comparison logic

#### Test 5: swarm_sync_node_configuration - remove nodes
- [ ] **RED**: Write test for `swarm_sync_should_remove_extra_nodes`
- [ ] **GREEN**: Implement node removal logic
- [ ] **REFACTOR**: Extract node removal logic

#### Test 6: swarm_sync_node_configuration - update labels
- [ ] **RED**: Write test for `swarm_sync_should_update_node_labels`
- [ ] **GREEN**: Implement label management
- [ ] **REFACTOR**: Extract label management logic

#### Test 7: swarm_display_status function
- [ ] **RED**: Write test for `swarm_display_status_should_show_nodes_and_services`
- [ ] **GREEN**: Implement status display
- [ ] **REFACTOR**: Format output consistently

### Phase 3: Integration Tests
- [ ] **RED**: Write test for `swarm_initialize_cluster_should_setup_complete_cluster`
- [ ] **GREEN**: Implement complete cluster initialization
- [ ] **REFACTOR**: Optimize initialization workflow

### Phase 4: Error Handling & Edge Cases
- [ ] **RED**: Write tests for error conditions (missing files, network failures, etc.)
- [ ] **GREEN**: Add comprehensive error handling
- [ ] **REFACTOR**: Standardize error reporting

### Phase 5: Interface Improvement (Tidy First - Structural Changes)
- [ ] Rename functions for clarity:
  - `swarm_create_ssl_secrets` → `swarm_setup_certificates`
  - `swarm_initialize_cluster` → `swarm_setup_cluster`
  - `swarm_sync_node_configuration` → `swarm_sync_nodes`
- [ ] Add help/usage functions
- [ ] Verify all tests pass with new interface

### Phase 6: Advanced Features
- [ ] **RED**: Write tests for cluster health checking
- [ ] **GREEN**: Implement health monitoring
- [ ] **REFACTOR**: Optimize monitoring logic

## Commit Strategy
- **Structural commits**: "tidy: extract docker wrapper interface"
- **Behavioral commits**: "feat: add swarm manager initialization with tests"
- **Refactor commits**: "refactor: extract IP resolution from swarm manager init"

## Success Criteria
- [ ] 100% test coverage for swarm functions
- [ ] All external dependencies wrapped and testable
- [ ] Clear, intuitive function interface
- [ ] Comprehensive error handling
- [ ] No behavioral regressions
- [ ] Clean, maintainable code structure

## Next Action
Start with creating wrapper interfaces (structural changes first, following Tidy First principles).
