#!/usr/bin/env bats

setup() {
    # Load test helper functions
    load test_helper

    # Create temporary test directory
    TEST_TEMP_DIR="$(temp_make)"

    # Set up test environment variables
    export TEST=true

    # Change to test directory
    cd "$TEST_TEMP_DIR" || return
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"
}

@test "selfhosted_script_should_show_usage_for_unknown_command" {
    run bash "${BATS_TEST_DIRNAME}/../../../selfhosted.sh" unknown
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"{compose|swarm|k8s|machines}"* ]]
}

@test "selfhosted_script_should_show_usage_for_no_arguments" {
    run bash "${BATS_TEST_DIRNAME}/../../../selfhosted.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"init-certs|list|sync-files"* ]]
}

@test "selfhosted_script_should_have_correct_shebang" {
    # Check that script starts with #!/bin/bash (the second shebang)
    run head -n1 "${BATS_TEST_DIRNAME}/../../../selfhosted.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == "#!/bin/bash" ]]
}

@test "selfhosted_script_should_be_executable" {
    # Check that the script has executable permissions
    [ -x "${BATS_TEST_DIRNAME}/../../../selfhosted.sh" ]
}

@test "selfhosted_script_should_contain_case_statement" {
    # Test that the script contains the main case statement
    run grep -A 10 "case.*\$1.*in" "${BATS_TEST_DIRNAME}/../../../selfhosted.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"init-certs"* ]]
    [[ "$output" == *"list"* ]]

    # Check for deployment targets in a separate grep
    run grep "compose|swarm|k8s|machines" "${BATS_TEST_DIRNAME}/../../../selfhosted.sh"
    [ "$status" -eq 0 ]
}

@test "selfhosted_script_should_source_required_files" {
    # Test that the script sources required dependencies
    run grep "source.*scripts" "${BATS_TEST_DIRNAME}/../../../selfhosted.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scripts/common.sh"* ]]
    [[ "$output" == *"scripts/machines.sh"* ]]
}

@test "selfhosted_script_should_handle_deployment_targets" {
    # Test that the script contains logic for deployment targets
    run grep -A 10 "compose|swarm|k8s|machines" "${BATS_TEST_DIRNAME}/../../../selfhosted.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"command_exists"* ]]
    [[ "$output" == *"shift 2"* ]]
}
