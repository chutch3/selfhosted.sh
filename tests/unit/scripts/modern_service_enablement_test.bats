#!/usr/bin/env bats

setup() {
    # Load test helper functions
    load test_helper
    load ../../helpers/homelab_builder

    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"

    # Set up test environment variables
    export TEST=true
    export BASE_DOMAIN="test.local"
    export PROJECT_ROOT="${TEST_TEMP_DIR}"
    export HOMELAB_CONFIG="${TEST_TEMP_DIR}/homelab.yaml"
    export ENABLED_SERVICES_FILE="${TEST_TEMP_DIR}/.enabled-services"

    # Create config directory structure
    mkdir -p "${TEST_TEMP_DIR}/config"
    mkdir -p "${TEST_TEMP_DIR}/config/services/reverseproxy/templates/conf.d/enabled"

    # Create test homelab.yaml with services
    create_homelab_with_services "$HOMELAB_CONFIG" "actual" "homepage"
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"

    # Unset test environment variables
    unset TEST BASE_DOMAIN PROJECT_ROOT HOMELAB_CONFIG ENABLED_SERVICES_FILE
}

@test "enable_services_via_yaml should mark services as enabled in homelab.yaml" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # This function should exist (will implement)
    run enable_services_via_yaml "actual" "homepage"

    # Check exit status
    [ "$status" -eq 0 ]

    # Should update homelab.yaml with enabled: true
    run yq '.services.actual.enabled' "$HOMELAB_CONFIG"
    [ "$output" = "true" ]

    run yq '.services.homepage.enabled' "$HOMELAB_CONFIG"
    [ "$output" = "true" ]
}

@test "disable_services_via_yaml should mark services as disabled in services.yaml" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # Enable services first
    enable_services_via_yaml "actual" "homepage"

    # Now disable one
    run disable_services_via_yaml "actual"

    # Check exit status
    [ "$status" -eq 0 ]

    # Should update services.yaml with enabled: false
    run yq '.services.actual.enabled' "${SERVICES_CONFIG}"
    [ "$output" = "false" ]

    # Homepage should still be enabled
    run yq '.services.homepage.enabled' "${SERVICES_CONFIG}"
    [ "$output" = "true" ]
}

@test "list_enabled_services_from_yaml should show only enabled services" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # Enable some services
    enable_services_via_yaml "actual" "homepage"

    # List enabled services
    run list_enabled_services_from_yaml

    # Check exit status
    [ "$status" -eq 0 ]

    # Should contain enabled services
    [[ "$output" =~ "actual" ]]
    [[ "$output" =~ "homepage" ]]

    # Should not contain disabled services
    [[ ! "$output" =~ "cryptpad" ]]
}

@test "generate_enabled_services_from_yaml should create .enabled-services file for backward compatibility" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # Enable some services in services.yaml
    enable_services_via_yaml "actual" "homepage"

    # Generate .enabled-services file
    run generate_enabled_services_from_yaml

    # Check exit status
    [ "$status" -eq 0 ]

    # Should create .enabled-services file
    [ -f "${ENABLED_SERVICES_FILE}" ]

    # Should contain enabled services
    run grep "actual" "${ENABLED_SERVICES_FILE}"
    [ "$status" -eq 0 ]

    run grep "homepage" "${ENABLED_SERVICES_FILE}"
    [ "$status" -eq 0 ]

    # Should not contain disabled services
    run grep "cryptpad" "${ENABLED_SERVICES_FILE}"
    [ "$status" -ne 0 ]
}

@test "start_enabled_services_modern should only start services marked as enabled in services.yaml" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # Enable some services
    enable_services_via_yaml "actual" "homepage"

    # Mock docker compose command
    docker() {
        echo "docker $*"
        return 0
    }
    export -f docker

    # Test the modern start function
    run start_enabled_services_modern

    # Check exit status
    [ "$status" -eq 0 ]

    # Should include enabled services in docker compose command
    [[ "$output" =~ "actual" ]]
    [[ "$output" =~ "homepage" ]]
}

@test "migrate_from_legacy_enabled_services should move .enabled-services to homelab.yaml" {
    skip "Migration function removed - migration completed in previous phase"
}

@test "interactive_service_enablement should be a callable function" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # Test the function exists (type check)
    run type interactive_service_enablement

    # Check exit status
    [ "$status" -eq 0 ]

    # Should be recognized as a function
    [[ "$output" =~ "function" ]]
}

@test "services.yaml should preserve enabled state across generation operations" {
    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    # Enable some services
    enable_services_via_yaml "actual" "homepage"

    # Generate other files (should not affect enabled state)
    generate_compose_from_services
    generate_nginx_from_services
    generate_domains_from_services

    # Enabled state should still be preserved
    run yq '.services.actual.enabled' "${SERVICES_CONFIG}"
    [ "$output" = "true" ]

    run yq '.services.homepage.enabled' "${SERVICES_CONFIG}"
    [ "$output" = "true" ]

    run yq '.services.cryptpad.enabled' "${SERVICES_CONFIG}"
    # Should be false or null (default disabled)
    [[ "$output" = "false" || "$output" = "null" ]]
}
