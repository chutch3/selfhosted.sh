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

    # Create test services config with volume definitions
    mkdir -p "$TEST_TEMP_DIR/config"
    cat > "$TEST_TEMP_DIR/config/services.yaml" <<EOF
version: "1.0"
categories:
  finance: "Finance & Budgeting"
  media: "Media Management"
services:
  actual:
    name: "Actual Budget"
    description: "Personal finance application"
    category: finance
    domain: "budget"
    volumes:
      - name: "data"
        description: "Application data and database"
        type: "application_data"
        size: "1GB"
        backup_priority: "high"
    compose:
      image: "actualbudget/actual-server:latest"
      volumes:
        - "\${VOLUME_ACTUAL_DATA}:/app/data"
    nginx:
      upstream: "actual:5006"
  photoprism:
    name: "PhotoPrism"
    description: "Photo management"
    category: media
    domain: "photos"
    volumes:
      - name: "config"
        description: "Configuration files"
        type: "config"
        size: "100MB"
        backup_priority: "medium"
      - name: "photos"
        description: "Photo storage"
        type: "media"
        size: "500GB"
        backup_priority: "high"
      - name: "cache"
        description: "Thumbnail cache"
        type: "cache"
        size: "50GB"
        backup_priority: "low"
    compose:
      image: "photoprism/photoprism:latest"
      volumes:
        - "\${VOLUME_PHOTOPRISM_CONFIG}:/photoprism/config"
        - "\${VOLUME_PHOTOPRISM_PHOTOS}:/photoprism/originals"
        - "\${VOLUME_PHOTOPRISM_CACHE}:/photoprism/cache"
    nginx:
      upstream: "photoprism:2342"
EOF

    # Create volume management config
    cat > "$TEST_TEMP_DIR/config/volumes.yaml" <<EOF
version: "1.0"
storage:
  # Local storage configuration
  local:
    enabled: true
    base_path: "/home/user/appdata"
    permissions:
      owner: "1000"
      group: "1000"
      mode: "755"

  # NFS storage configuration
  nfs:
    enabled: false
    server: "192.168.1.100"
    export_path: "/srv/nfs/appdata"
    mount_point: "/mnt/nas"
    mount_options: "vers=4,rsize=1048576,wsize=1048576,hard,intr,timeo=600"
    permissions:
      owner: "1000"
      group: "1000"
      mode: "755"

# Volume type defaults
volume_types:
  application_data:
    backup_priority: "high"
    permissions: "755"
  config:
    backup_priority: "medium"
    permissions: "755"
  media:
    backup_priority: "high"
    permissions: "755"
  cache:
    backup_priority: "low"
    permissions: "777"
  logs:
    backup_priority: "low"
    permissions: "755"
EOF

    # Change to test directory
    cd "$TEST_TEMP_DIR" || return

    # Source the volume management script
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/volume_manager.sh"
}

teardown() {
    # Clean up test directory
    temp_del "$TEST_TEMP_DIR"
}

@test "volume_manager_script_should_exist" {
    # Test that the volume manager script exists
    [ -f "${BATS_TEST_DIRNAME}/../../../scripts/volume_manager.sh" ]
}

@test "generate_volume_paths_should_create_local_structure" {
    # Test local volume path generation
    export VOLUME_STORAGE_TYPE="local"
    export VOLUME_BASE_PATH="/home/user/appdata"

    run generate_volume_paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"VOLUME_ACTUAL_DATA=/home/user/appdata/actual/data"* ]]
    [[ "$output" == *"VOLUME_PHOTOPRISM_CONFIG=/home/user/appdata/photoprism/config"* ]]
    [[ "$output" == *"VOLUME_PHOTOPRISM_PHOTOS=/home/user/appdata/photoprism/photos"* ]]
}

@test "generate_volume_paths_should_create_nfs_structure" {
    # Test NFS volume path generation
    export VOLUME_STORAGE_TYPE="nfs"
    export VOLUME_BASE_PATH="/mnt/nas"

    run generate_volume_paths
    [ "$status" -eq 0 ]
    [[ "$output" == *"VOLUME_ACTUAL_DATA=/mnt/nas/actual/data"* ]]
    [[ "$output" == *"VOLUME_PHOTOPRISM_CONFIG=/mnt/nas/photoprism/config"* ]]
    [[ "$output" == *"VOLUME_PHOTOPRISM_PHOTOS=/mnt/nas/photoprism/photos"* ]]
}

@test "validate_volume_config_should_check_storage_accessibility" {
    # Test volume configuration validation
    export VOLUME_STORAGE_TYPE="local"
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"

    # Create the base directory
    mkdir -p "$TEST_TEMP_DIR/appdata"

    run validate_volume_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"Volume configuration is valid"* ]]
}

@test "setup_nfs_mount_should_configure_nfs" {
    # Test NFS mount setup (dry run)
    export VOLUME_STORAGE_TYPE="nfs"
    export NFS_SERVER="192.168.1.100"
    export NFS_EXPORT_PATH="/srv/nfs/appdata"
    export NFS_MOUNT_POINT="/mnt/nas"

    run setup_nfs_mount --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would mount"* ]]
    [[ "$output" == *"192.168.1.100:/srv/nfs/appdata"* ]]
    [[ "$output" == *"/mnt/nas"* ]]
}

@test "create_volume_directories_should_setup_local_structure" {
    # Test local volume directory creation
    export VOLUME_STORAGE_TYPE="local"
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"
    export VOLUME_OWNER="1000"
    export VOLUME_GROUP="1000"

    run create_volume_directories
    [ "$status" -eq 0 ]

    # Check directories were created
    [ -d "$TEST_TEMP_DIR/appdata/actual/data" ]
    [ -d "$TEST_TEMP_DIR/appdata/photoprism/config" ]
    [ -d "$TEST_TEMP_DIR/appdata/photoprism/photos" ]
    [ -d "$TEST_TEMP_DIR/appdata/photoprism/cache" ]
}

@test "generate_backup_config_should_create_backup_script" {
    # Test backup configuration generation
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"

    run generate_backup_config
    [ "$status" -eq 0 ]
    [ -f "$PROJECT_ROOT/backup-config.sh" ]

    # Check backup script contains volume paths
    run grep "actual/data" "$PROJECT_ROOT/backup-config.sh"
    [ "$status" -eq 0 ]

    run grep "photoprism/photos" "$PROJECT_ROOT/backup-config.sh"
    [ "$status" -eq 0 ]
}

@test "show_volume_usage_should_display_storage_info" {
    # Test volume usage display
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"
    mkdir -p "$TEST_TEMP_DIR/appdata/actual/data"
    mkdir -p "$TEST_TEMP_DIR/appdata/photoprism/photos"

    # Create some test files
    echo "test data" > "$TEST_TEMP_DIR/appdata/actual/data/test.txt"
    echo "test photo" > "$TEST_TEMP_DIR/appdata/photoprism/photos/test.jpg"

    run show_volume_usage
    [ "$status" -eq 0 ]
    [[ "$output" == *"Volume Usage Report"* ]]
    [[ "$output" == *"actual/data"* ]]
    [[ "$output" == *"photoprism/photos"* ]]
}

@test "migrate_volumes_should_move_data_between_storage_types" {
    # Test volume migration between storage types
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"
    mkdir -p "$TEST_TEMP_DIR/appdata/actual/data"
    echo "test data" > "$TEST_TEMP_DIR/appdata/actual/data/test.txt"

    # Setup target directory
    mkdir -p "$TEST_TEMP_DIR/new_storage"
    export NEW_VOLUME_BASE_PATH="$TEST_TEMP_DIR/new_storage"

    run migrate_volumes "$TEST_TEMP_DIR/appdata" "$TEST_TEMP_DIR/new_storage" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would migrate"* ]]
    [[ "$output" == *"actual/data"* ]]
}

@test "check_volume_permissions_should_validate_access" {
    # Test volume permission checking
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"
    mkdir -p "$TEST_TEMP_DIR/appdata/actual/data"

    run check_volume_permissions
    [ "$status" -eq 0 ]
    [[ "$output" == *"Volume permissions are valid"* ]]
}

@test "integrate_with_service_generator_should_update_compose_volumes" {
    # Test integration with service generator
    export VOLUME_STORAGE_TYPE="local"
    export VOLUME_BASE_PATH="$TEST_TEMP_DIR/appdata"

    # Load service generator
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../../../scripts/service_generator.sh"

    run generate_compose_with_volumes
    [ "$status" -eq 0 ]

    # Check that generated compose file has volume paths
    run grep "VOLUME_ACTUAL_DATA" "$PROJECT_ROOT/generated-docker-compose.yaml"
    [ "$status" -eq 0 ]

    run grep "VOLUME_PHOTOPRISM_PHOTOS" "$PROJECT_ROOT/generated-docker-compose.yaml"
    [ "$status" -eq 0 ]
}
