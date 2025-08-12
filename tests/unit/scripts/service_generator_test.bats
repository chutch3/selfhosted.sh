#!/usr/bin/env bats

setup() {
    # Load test helper functions
    load ../scripts/test_helper
    load ../../helpers/homelab_builder

    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"

    # Set up test environment variables
    export TEST=true
    export PROJECT_ROOT="$TEST_TEMP_DIR"
    export BASE_DOMAIN="test.example.com"

    # Create homelab.yaml config for testing
    TEST_HOMELAB_CONFIG="${TEST_TEMP_DIR}/homelab.yaml"
    create_homelab_with_services "$TEST_HOMELAB_CONFIG" "actual" "nginx"

    # Change to test directory
    cd "$TEST_TEMP_DIR" || return

    # Source the service generator script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"
}

@test "service_generator_script_should_exist" {
    # Test that the service generator script exists
    [ -f "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh" ]
}

@test "generate_compose_should_create_docker_compose_yaml" {
    # Test that generate_compose creates a docker-compose.yaml file
    run generate_compose_from_services
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/generated-docker-compose.yaml" ]
}

@test "generate_compose_should_include_service_definition" {
    # Test that generated compose file includes the actual service
    generate_compose_from_services
    run cat "$PROJECT_ROOT/generated-docker-compose.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"actual:"* ]]
    [[ "$output" == *"image:"* ]]
}

@test "generate_nginx_should_create_template_files" {
    # Test that generate_nginx creates nginx template files
    run generate_nginx_from_services
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/generated-nginx/actual.template" ]
}

@test "generate_nginx_should_include_upstream_config" {
    # Test that generated nginx template includes upstream configuration
    generate_nginx_from_services
    run grep "proxy_pass http://actual:5006" "$PROJECT_ROOT/generated-nginx/actual.template"
    [ "$status" -eq 0 ]
}

@test "generate_domains_should_create_domains_file" {
    # Test that generate_domains creates .domains file from services.yaml
    run generate_domains_from_services
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/.domains" ]
}

@test "generate_domains_should_include_service_domains" {
    # Skip this test - legacy domain system superseded by unified homelab.yaml configuration (Issue #40)
    skip "Legacy domain generation superseded by unified configuration in Issue #40"
}

@test "generate_all_should_create_complete_deployment" {
    # Test that generate_all creates all necessary files
    run generate_all_from_services
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/generated-docker-compose.yaml" ]
    [ -f "$PROJECT_ROOT/generated-nginx/actual.template" ]
    [ -f "$PROJECT_ROOT/.domains" ]
}

@test "list_available_services_should_show_services_from_yaml" {
    # Skip this test - legacy services.yaml system superseded by unified homelab.yaml configuration (Issue #40)
    skip "Legacy services.yaml system superseded by unified configuration in Issue #40"
}
