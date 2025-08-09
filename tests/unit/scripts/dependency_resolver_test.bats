#!/usr/bin/env bats

setup() {
    # Load test helper functions
    load ../scripts/test_helper

    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"

    # Set up test environment variables
    export TEST=true
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    export BASE_DOMAIN="example.com"

    # Create test services config with dependencies
    mkdir -p "$TEST_TEMP_DIR/config"
    cat > "$TEST_TEMP_DIR/config/services.yaml" <<EOF
version: "1.0"
categories:
  database: "Database Services"
  finance: "Finance & Budgeting"
  media: "Media Management"

services:
  # Database service (no dependencies)
  mariadb:
    name: "MariaDB"
    description: "Database server"
    category: database
    domain: "db"
    port: 3306
    startup_priority: 1
    health_check:
      enabled: true
      endpoint: "/health"
      timeout: 30
    compose:
      image: "mariadb:latest"
      environment:
        - "MYSQL_ROOT_PASSWORD=rootpass"
    nginx:
      upstream: "mariadb:3306"

  # Service with database dependency
  photoprism:
    name: "PhotoPrism"
    description: "Photo management"
    category: media
    domain: "photos"
    port: 2342
    startup_priority: 3
    depends_on:
      - mariadb
    health_check:
      enabled: true
      endpoint: "/api/v1/status"
      timeout: 60
    compose:
      image: "photoprism/photoprism:latest"
      environment:
        - "PHOTOPRISM_DATABASE_SERVER=mariadb:3306"
    nginx:
      upstream: "photoprism:2342"

  # Service with multiple dependencies
  actual:
    name: "Actual Budget"
    description: "Personal finance application"
    category: finance
    domain: "budget"
    port: 5006
    startup_priority: 5
    depends_on:
      - mariadb
      - photoprism
    health_check:
      enabled: true
      endpoint: "/health"
      timeout: 45
    compose:
      image: "actualbudget/actual-server:latest"
    nginx:
      upstream: "actual:5006"

  # Independent service (no dependencies)
  homepage:
    name: "Homepage"
    description: "Dashboard"
    category: core
    domain: "dashboard"
    port: 3000
    startup_priority: 2
    compose:
      image: "ghcr.io/gethomepage/homepage:latest"
    nginx:
      upstream: "homepage:3000"

  # Service with circular dependency (should be detected)
  circular-a:
    name: "Circular A"
    description: "Service A in circular dependency"
    category: test
    domain: "circular-a"
    port: 8001
    depends_on:
      - circular-b
    compose:
      image: "test/circular-a:latest"

  circular-b:
    name: "Circular B"
    description: "Service B in circular dependency"
    category: test
    domain: "circular-b"
    port: 8002
    depends_on:
      - circular-a
    compose:
      image: "test/circular-b:latest"
EOF

    # Change to test directory
    cd "$TEST_TEMP_DIR" || return

    # Source the dependency resolver script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/dependency_resolver.sh"
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"
}

@test "dependency_resolver_script_should_exist" {
    # Test that the dependency resolver script exists
    [ -f "${BATS_TEST_DIRNAME}/../../../scripts/dependency_resolver.sh" ]
}

@test "resolve_dependencies_should_return_correct_startup_order" {
    # Test basic dependency resolution
    run resolve_service_dependencies
    [ "$status" -eq 0 ]

    # Check that mariadb comes before photoprism
    [[ "$output" == *"mariadb"* ]]
    [[ "$output" == *"photoprism"* ]]
    [[ "$output" == *"actual"* ]]

    # Verify startup order by checking line positions
    mariadb_line=$(echo "$output" | grep -n "mariadb" | head -1 | cut -d: -f1)
    photoprism_line=$(echo "$output" | grep -n "photoprism" | head -1 | cut -d: -f1)
    actual_line=$(echo "$output" | grep -n "actual" | head -1 | cut -d: -f1)

    [ "$mariadb_line" -lt "$photoprism_line" ]
    [ "$photoprism_line" -lt "$actual_line" ]
}

@test "detect_circular_dependencies_should_find_circular_refs" {
    # Test circular dependency detection
    run detect_circular_dependencies
    [ "$status" -eq 1 ]  # Should fail with circular dependency
    [[ "$output" == *"Circular dependency detected"* ]]
    # Should mention at least one of the circular services
    [[ "$output" == *"circular-a"* || "$output" == *"circular-b"* ]]
}

@test "generate_startup_order_should_respect_priorities" {
    # Test startup order generation with priorities
    run generate_startup_order
    [ "$status" -eq 0 ]

    # Verify priority ordering (lower numbers start first)
    priority1_line=$(echo "$output" | grep -n "priority: 1" | head -1 | cut -d: -f1)
    priority2_line=$(echo "$output" | grep -n "priority: 2" | head -1 | cut -d: -f1)
    priority3_line=$(echo "$output" | grep -n "priority: 3" | head -1 | cut -d: -f1)

    [ "$priority1_line" -lt "$priority2_line" ]
    [ "$priority2_line" -lt "$priority3_line" ]
}

@test "validate_service_dependencies_should_check_existence" {
    # Test service dependency validation
    run validate_service_dependencies
    [ "$status" -eq 0 ]
    [[ "$output" == *"All service dependencies are valid"* ]]
}

@test "get_service_dependents_should_find_reverse_deps" {
    # Test finding services that depend on a given service
    run get_service_dependents "mariadb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"photoprism"* ]]
    [[ "$output" == *"actual"* ]]
}

@test "generate_dependency_graph_should_create_visual_graph" {
    # Test dependency graph generation
    run generate_dependency_graph
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/dependency-graph.md" ]

    # Check graph content
    run grep "mariadb" "$PROJECT_ROOT/dependency-graph.md"
    [ "$status" -eq 0 ]

    run grep "photoprism" "$PROJECT_ROOT/dependency-graph.md"
    [ "$status" -eq 0 ]
}

@test "check_service_health_should_validate_endpoints" {
    # Test service health checking (dry run)
    export HEALTH_CHECK_DRY_RUN=true

    run check_service_health "mariadb"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would check health"* ]]
    [[ "$output" == *"mariadb"* ]]
}

@test "wait_for_service_dependencies_should_check_health" {
    # Test waiting for service dependencies (dry run)
    export HEALTH_CHECK_DRY_RUN=true

    run wait_for_service_dependencies "photoprism"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Waiting for dependencies"* ]]
    [[ "$output" == *"mariadb"* ]]
}

@test "generate_docker_compose_with_depends_on_should_add_dependency_blocks" {
    # Test Docker Compose generation with dependency ordering
    run generate_docker_compose_with_dependencies
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/generated-docker-compose.yaml" ]

    # Check that depends_on blocks are added
    run grep -A 5 "depends_on:" "$PROJECT_ROOT/generated-docker-compose.yaml"
    [ "$status" -eq 0 ]

    # Check that mariadb is listed as dependency for photoprism
    run grep -A 10 "photoprism:" "$PROJECT_ROOT/generated-docker-compose.yaml" | grep "mariadb"
    [ "$status" -eq 0 ]
}

@test "generate_startup_script_should_create_ordered_startup" {
    # Test startup script generation
    run generate_startup_script
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/startup-services.sh" ]

    # Check script contains both services
    run grep "mariadb" "$PROJECT_ROOT/startup-services.sh"
    [ "$status" -eq 0 ]

    run grep "photoprism" "$PROJECT_ROOT/startup-services.sh"
    [ "$status" -eq 0 ]
}

@test "shutdown_services_should_reverse_startup_order" {
    # Test service shutdown ordering (reverse of startup)
    run generate_shutdown_script
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/shutdown-services.sh" ]

    # Check script contains both services
    run grep "actual" "$PROJECT_ROOT/shutdown-services.sh"
    [ "$status" -eq 0 ]

    run grep "photoprism" "$PROJECT_ROOT/shutdown-services.sh"
    [ "$status" -eq 0 ]
}
