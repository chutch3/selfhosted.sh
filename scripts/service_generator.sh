#!/bin/bash

# Service Generator
# Generates deployment files (docker-compose, nginx templates, domains) from unified services.yaml

# Set default paths
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
SERVICES_CONFIG="${SERVICES_CONFIG:-$PROJECT_ROOT/config/services.yaml}"
GENERATED_COMPOSE="${GENERATED_COMPOSE:-$PROJECT_ROOT/generated-docker-compose.yaml}"
GENERATED_NGINX_DIR="${GENERATED_NGINX_DIR:-$PROJECT_ROOT/generated-nginx}"
DOMAINS_FILE="${DOMAINS_FILE:-$PROJECT_ROOT/.domains}"

# Function: generate_compose_from_services
# Description: Generates a docker-compose.yaml file from services.yaml
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_compose_from_services() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🔧 Generating docker-compose.yaml from services configuration..."

    # Start the compose file
    cat > "$GENERATED_COMPOSE" <<EOF
# Generated docker-compose.yaml from config/services.yaml
# DO NOT EDIT - This file is auto-generated

services:
EOF

    # Extract services from YAML and generate compose entries
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        echo "  Processing service: $service_key"

        # Add service name and configuration
        {
            echo "  ${service_key}:"
            # Get service compose configuration and properly indent (convert from JSON to YAML)
            # Try different yq versions - first attempt with --yaml-output (python yq)
            # If that fails, try without flag (go yq)
            if ! yq --yaml-output ".services[\"${service_key}\"].compose" "$SERVICES_CONFIG" 2>/dev/null; then
                yq ".services[\"${service_key}\"].compose" "$SERVICES_CONFIG"
            fi | sed 's/^/    /'
            echo ""
        } >> "$GENERATED_COMPOSE"
    done

    # Add networks section
    cat >> "$GENERATED_COMPOSE" <<EOF

networks:
  reverseproxy:
    driver: bridge
EOF

    echo "✅ Generated docker-compose.yaml at $GENERATED_COMPOSE"
    return 0
}

# Function: generate_nginx_from_services
# Description: Generates nginx template files from services.yaml with hybrid approach
# Supports: default templates, inline config, and external template references
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_nginx_from_services() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🌐 Generating nginx templates from services configuration..."

    # Create nginx directory
    mkdir -p "$GENERATED_NGINX_DIR"

    # Extract services and generate nginx templates
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        echo "  Processing nginx config for: $service_key"

        # Check if service uses external template file
        template_file=$(yq -r ".services[\"${service_key}\"].nginx.template_file" "$SERVICES_CONFIG")
        if [ "$template_file" != "null" ] && [ -n "$template_file" ]; then
            echo "    → Using external template: $template_file"
            # Skip generation - external template will be used directly
            continue
        fi

        # Get configuration values
        domain=$(yq ".services[\"${service_key}\"].domain" "$SERVICES_CONFIG" | tr -d '"')
        upstream=$(yq -r ".services[\"${service_key}\"].nginx.upstream" "$SERVICES_CONFIG")
        additional_config=$(yq -r ".services[\"${service_key}\"].nginx.additional_config" "$SERVICES_CONFIG")

        # Generate normalized domain variable name
        domain_var=$(normalize_service_name_for_env "$service_key")

        # Start generating the template
        cat > "$GENERATED_NGINX_DIR/${service_key}.template" <<EOF
# Generated nginx template for $service_key
# HTTP to HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name \${DOMAIN_${domain_var}};

    return 301 https://\$host\$request_uri;
}

# HTTPS server
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name \${DOMAIN_${domain_var}};

    include /etc/nginx/conf.d/includes/ssl;

EOF

        # Add custom configuration or default proxy setup
        if [ "$additional_config" != "null" ] && [ -n "$additional_config" ]; then
            # Use custom additional_config (with env var support)
            printf '%s\n' "$additional_config" | sed 's/^/    /' >> "$GENERATED_NGINX_DIR/${service_key}.template"
        else
            # Use default proxy configuration
            if [ "$upstream" != "null" ] && [ -n "$upstream" ]; then
                cat >> "$GENERATED_NGINX_DIR/${service_key}.template" <<EOF
    location / {
        include /etc/nginx/conf.d/includes/proxy;
        proxy_pass http://$upstream;
    }
EOF
            fi
        fi

        # Add closing and logging
        cat >> "$GENERATED_NGINX_DIR/${service_key}.template" <<EOF

    access_log off;
    error_log  /var/log/nginx/error.log error;
}
EOF
    done

    echo "✅ Generated nginx templates in $GENERATED_NGINX_DIR"
    return 0
}

# Function: normalize_service_name_for_env
# Description: Normalizes service name for use in environment variables
# Arguments: $1 - service name
# Returns: Normalized environment variable name
normalize_service_name_for_env() {
    local service_name="$1"
    # Convert to uppercase and replace special characters with underscores
    echo "$service_name" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g'
}

# Function: validate_domain_patterns
# Description: Validates domain naming patterns in services.yaml
# Arguments: None
# Returns: 0 if valid, 1 if invalid
validate_domain_patterns() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

        echo "🔍 Validating domain patterns..."

    local errors=0
    local temp_errors="/tmp/domain_errors_$$"
    echo "0" > "$temp_errors"

    # Check each service's domain pattern
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        domain=$(yq ".services[\"${service_key}\"].domain" "$SERVICES_CONFIG" | tr -d '"')

        if [ "$domain" != "null" ]; then
            # Check domain naming conventions (lowercase, no special chars except hyphens)
            if ! echo "$domain" | grep -q '^[a-z0-9-]*$'; then
                echo "⚠️  Warning: Domain '$domain' for service '$service_key' contains invalid characters"
                echo "   Domains should only contain lowercase letters, numbers, and hyphens"
                current_errors=$(cat "$temp_errors")
                echo $((current_errors + 1)) > "$temp_errors"
            fi

            # Check for reserved domain names
            case "$domain" in
                www|mail|ftp|admin|root|localhost)
                    echo "⚠️  Warning: Domain '$domain' for service '$service_key' uses reserved name"
                    current_errors=$(cat "$temp_errors")
                    echo $((current_errors + 1)) > "$temp_errors"
                    ;;
            esac
        fi
    done

    errors=$(cat "$temp_errors")
    rm -f "$temp_errors"

    if [ "$errors" -eq 0 ]; then
        echo "✅ Domain patterns are valid"
        return 0
    else
        echo "❌ Found $errors domain pattern issues"
        return 1
    fi
}

# Function: validate_domain_uniqueness
# Description: Validates that all domains are unique across services
# Arguments: None
# Returns: 0 if unique, 1 if duplicates found
validate_domain_uniqueness() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🔍 Checking domain uniqueness..."

    local temp_domains="/tmp/domains_$$"
    local duplicates="/tmp/duplicates_$$"

    # Extract all domains
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        domain=$(yq ".services[\"${service_key}\"].domain" "$SERVICES_CONFIG" | tr -d '"')
        if [ "$domain" != "null" ]; then
            echo "$domain"
        fi
    done > "$temp_domains"

    # Find duplicates
    sort "$temp_domains" | uniq -d > "$duplicates"

    if [ -s "$duplicates" ]; then
        echo "❌ Duplicate domain names found:"
        while read -r duplicate; do
            echo "   - $duplicate"
        done < "$duplicates"
        rm -f "$temp_domains" "$duplicates"
        return 1
    else
        echo "✅ All domains are unique"
        rm -f "$temp_domains" "$duplicates"
        return 0
    fi
}

# Function: suggest_domain_name
# Description: Suggests a domain name based on service name or description
# Arguments: $1 - service name or description
# Returns: Suggested domain name
suggest_domain_name() {
    local input="$1"

    # Convert to lowercase and extract key words
    local suggestion
    suggestion=$(echo "$input" | tr '[:upper:]' '[:lower:]' | \
        # Remove common words and extract meaningful terms
        sed 's/\bservice\b//g; s/\bapplication\b//g; s/\bmanagement\b//g; s/\bserver\b//g' | \
        # Extract first meaningful word
        grep -o '\b[a-z][a-z]*\b' | head -1)

    # Fallback suggestions based on common patterns
    case "$input" in
        *[Bb]udget*|*[Ff]inance*|*[Mm]oney*) suggestion="budget" ;;
        *[Pp]hoto*|*[Ii]mage*|*[Gg]allery*) suggestion="photos" ;;
        *[Hh]ome*|*[Aa]utomation*) suggestion="home" ;;
        *[Dd]ashboard*|*[Hh]omepage*) suggestion="dashboard" ;;
        *[Cc]hat*|*[Mm]essage*) suggestion="chat" ;;
        *[Mm]edia*|*[Ss]tream*) suggestion="media" ;;
        *[Dd]ocs*|*[Dd]ocument*) suggestion="docs" ;;
        *[Cc]loud*|*[Ss]torage*) suggestion="cloud" ;;
    esac

    echo "${suggestion:-app}"
}

# Function: generate_domain_mapping
# Description: Generates a human-readable domain mapping reference file
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_domain_mapping() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "📋 Generating domain mapping reference..."

    local mapping_file="$PROJECT_ROOT/DOMAINS.md"

    cat > "$mapping_file" <<EOF
# Domain Mapping Reference

This file is auto-generated from \`config/services.yaml\`. It provides a quick reference for all service domains.

## Service Domains

| Service | Domain | Full URL |
|---------|--------|----------|
EOF

    # Generate table rows
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        name=$(yq ".services[\"${service_key}\"].name" "$SERVICES_CONFIG" | tr -d '"')
        domain=$(yq ".services[\"${service_key}\"].domain" "$SERVICES_CONFIG" | tr -d '"')

        if [ "$domain" != "null" ]; then
            echo "| $name | \`$domain\` | https://$domain.${BASE_DOMAIN:-\${BASE_DOMAIN\}} |" >> "$mapping_file"
        fi
    done

    cat >> "$mapping_file" <<EOF

## Environment Variables

These environment variables are automatically generated in \`.domains\`:

EOF

    # Generate environment variable list
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        domain=$(yq ".services[\"${service_key}\"].domain" "$SERVICES_CONFIG" | tr -d '"')

        if [ "$domain" != "null" ]; then
            domain_var=$(normalize_service_name_for_env "$service_key")
            echo "- \`DOMAIN_${domain_var}=$domain.${BASE_DOMAIN:-\${BASE_DOMAIN\}}\`" >> "$mapping_file"
        fi
    done

    echo "" >> "$mapping_file"
    echo "*Generated on $(date)*" >> "$mapping_file"

    echo "✅ Generated domain mapping at $mapping_file"
    return 0
}

# Function: generate_domains_from_services
# Description: Generates .domains file from services.yaml with improved handling
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_domains_from_services() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🏷️ Generating domains file from services configuration..."

    # Start the domains file
    cat > "$DOMAINS_FILE" <<EOF
# Generated domains file from config/services.yaml
# DO NOT EDIT - This file is auto-generated
# Generated $(date)

BASE_DOMAIN=${BASE_DOMAIN}
EOF

    # Extract services and generate domain variables with proper escaping
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        domain=$(yq ".services[\"${service_key}\"].domain" "$SERVICES_CONFIG" | tr -d '"')

        if [ "$domain" != "null" ]; then
            domain_var=$(normalize_service_name_for_env "$service_key")
            echo "DOMAIN_${domain_var}=${domain}.${BASE_DOMAIN}" >> "$DOMAINS_FILE"
        fi
    done

    echo "✅ Generated domains file at $DOMAINS_FILE"
    return 0
}

# Function: generate_swarm_stack_from_services
# Description: Generates Docker Swarm stack.yaml from services.yaml
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_swarm_stack_from_services() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🐳 Generating Docker Swarm stack from services configuration..."

    # Set output path
    local SWARM_STACK="${PROJECT_ROOT}/deployments/swarm/stack.yaml"
    mkdir -p "$(dirname "$SWARM_STACK")"

    # Start the swarm stack file with infrastructure services
    cat > "$SWARM_STACK" <<EOF
# Generated Docker Swarm stack from config/services.yaml
# DO NOT EDIT - This file is auto-generated
# Generated $(date)

services:
  # Reverse Proxy (Infrastructure)
  reverseproxy:
    image: nginx:alpine
    deploy:
      mode: global  # Run on all nodes
      restart_policy:
        condition: on-failure
    volumes:
      - \${PWD}/config/services/reverseproxy/templates/conf.d/enabled:/etc/nginx/templates/enabled:ro
      - \${PWD}/config/services/reverseproxy/templates/includes:/etc/nginx/templates/includes:ro
      - \${PWD}/config/services/reverseproxy/backend-not-found.html:/var/www/html/backend-not-found.html:ro
      - \${PWD}/config/services/reverseproxy/default.conf:/etc/nginx/conf.d/default.conf:ro
      - \${PWD}/scripts/sleep.sh:/docker-entrypoint.d/99-sleep.sh:ro
    secrets:
      - ssl_full.pem
      - ssl_key.pem
      - ssl_ca.pem
      - ssl_dhparam.pem
    environment:
      - BASE_DOMAIN
    ports:
      - "80:80"
      - "443:443"
    networks:
      - reverseproxy

EOF

    # Add services from services.yaml with swarm-specific config
    local services_list
    services_list=$(yq '.services | keys[]' "$SERVICES_CONFIG" | tr -d '"')

    while IFS= read -r service_key; do
        [ -z "$service_key" ] && continue
        echo "  Processing swarm config for: $service_key"

        # Get base configuration
        local image
        image=$(yq ".services[\"${service_key}\"].container.image" "$SERVICES_CONFIG" 2>/dev/null | tr -d '"')
        if [ "$image" = "null" ] || [ -z "$image" ]; then
            image=$(yq ".services[\"${service_key}\"].compose.image" "$SERVICES_CONFIG" 2>/dev/null | tr -d '"')
        fi

        if [ "$image" != "null" ] && [ -n "$image" ]; then
            # Add service to swarm stack
            cat >> "$SWARM_STACK" <<EOF
  # Generated from services.yaml: $service_key
  ${service_key}:
    image: $image
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
    networks:
      - reverseproxy

EOF
        fi
    done <<< "$services_list"

    # Add infrastructure sections
    cat >> "$SWARM_STACK" <<EOF
# Infrastructure Configuration
secrets:
  ssl_full.pem:
    external: true
  ssl_key.pem:
    external: true
  ssl_ca.pem:
    external: true
  ssl_dhparam.pem:
    external: true

networks:
  reverseproxy:
    driver: overlay  # Enable cross-node communication
    attachable: true
EOF

    echo "✅ Generated Docker Swarm stack at $SWARM_STACK"
    return 0
}

# Function: generate_all_from_services
# Description: Generates all deployment files from services.yaml
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_all_from_services() {
    echo "🚀 Generating all deployment files from services configuration..."

    generate_compose_from_services || return 1
    generate_nginx_from_services || return 1
    generate_domains_from_services || return 1
    generate_swarm_stack_from_services || return 1

    echo "✅ All deployment files generated successfully!"
    return 0
}

# Function: enable_services_via_yaml
# Description: Marks services as enabled in services.yaml
# Arguments: service names (space-separated)
# Returns: 0 on success, 1 on failure
enable_services_via_yaml() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    local services=("$@")

    for service in "${services[@]}"; do
        echo "✅ Enabling service: $service"

        # Check if service exists in config
        if ! yq ".services | has(\"$service\")" "$SERVICES_CONFIG" | grep -q "true"; then
            echo "❌ Error: Service '$service' not found in configuration"
            return 1
        fi

        # Set enabled: true for the service
        yq --yaml-output --in-place ".services[\"$service\"].enabled = true" "$SERVICES_CONFIG"
    done

    echo "🎉 Successfully enabled ${#services[@]} service(s)"
    return 0
}

# Function: disable_services_via_yaml
# Description: Marks services as disabled in services.yaml
# Arguments: service names (space-separated)
# Returns: 0 on success, 1 on failure
disable_services_via_yaml() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    local services=("$@")

    for service in "${services[@]}"; do
        echo "❌ Disabling service: $service"

        # Check if service exists in config
        if ! yq ".services | has(\"$service\")" "$SERVICES_CONFIG" | grep -q "true"; then
            echo "❌ Error: Service '$service' not found in configuration"
            return 1
        fi

        # Set enabled: false for the service
        yq --yaml-output --in-place ".services[\"$service\"].enabled = false" "$SERVICES_CONFIG"
    done

    echo "🎉 Successfully disabled ${#services[@]} service(s)"
    return 0
}

# Function: list_enabled_services_from_yaml
# Description: Lists all services marked as enabled in services.yaml
# Arguments: None
# Returns: 0 on success, 1 on failure
list_enabled_services_from_yaml() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "📋 Enabled services:"

    # Get all services where enabled = true
    local enabled_services
    enabled_services=$(yq '.services | to_entries | map(select(.value.enabled == true)) | .[].key' "$SERVICES_CONFIG" | tr -d '"')

    if [ -z "$enabled_services" ]; then
        echo "   No services currently enabled"
        return 0
    fi

    echo "$enabled_services" | while read -r service; do
        [ -n "$service" ] && echo "  ✅ $service"
    done

    return 0
}

# Function: generate_enabled_services_from_yaml
# Description: Creates .enabled-services file from services.yaml for backward compatibility
# Arguments: None
# Returns: 0 on success, 1 on failure
generate_enabled_services_from_yaml() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    local enabled_services_file="${PROJECT_ROOT}/.enabled-services"

    echo "📝 Generating .enabled-services file from services.yaml..."

    # Get all services where enabled = true and write to file
    yq '.services | to_entries | map(select(.value.enabled == true)) | .[].key' "$SERVICES_CONFIG" | tr -d '"' > "$enabled_services_file"

    local count
    count=$(wc -l < "$enabled_services_file")
    echo "✅ Generated .enabled-services with $count enabled service(s)"

    return 0
}

# Function: start_enabled_services_modern
# Description: Starts services marked as enabled in services.yaml using docker compose
# Arguments: None
# Returns: 0 on success, 1 on failure
start_enabled_services_modern() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🚀 Starting enabled services from services.yaml..."

    # Get enabled services as comma-separated list
    local enabled_services
    enabled_services=$(yq '.services | to_entries | map(select(.value.enabled == true)) | .[].key' "$SERVICES_CONFIG" | tr -d '"' | tr '\n' ',' | sed 's/,$//')

    if [ -z "$enabled_services" ]; then
        echo "⚠️  No services enabled, nothing to start"
        return 0
    fi

    echo "Starting services: $enabled_services"

    # Use docker compose with service selection
    # shellcheck disable=SC2086
    docker compose up -d $enabled_services

    return 0
}

# Function: migrate_from_legacy_enabled_services
# Description: Migrates from .enabled-services file to services.yaml enabled flags
# Arguments: None
# Returns: 0 on success, 1 on failure
migrate_from_legacy_enabled_services() {
    local legacy_file="${PROJECT_ROOT}/.enabled-services"

    if [ ! -f "$legacy_file" ]; then
        echo "ℹ️  No legacy .enabled-services file found, migration not needed"
        return 0
    fi

    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🔄 Migrating from legacy .enabled-services to services.yaml..."

    # First, set all services to disabled
    yq --yaml-output --in-place '.services |= with_entries(.value.enabled = false)' "$SERVICES_CONFIG"

    # Read legacy file and enable those services
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        echo "  Migrating: $service"

        if yq ".services | has(\"$service\")" "$SERVICES_CONFIG" | grep -q "true"; then
            yq --yaml-output --in-place ".services[\"$service\"].enabled = true" "$SERVICES_CONFIG"
        else
            echo "  ⚠️  Warning: Service '$service' not found in services.yaml, skipping"
        fi
    done < "$legacy_file"

    # Backup and remove legacy file
    cp "$legacy_file" "${legacy_file}.backup"
    rm "$legacy_file"

    echo "✅ Migration completed. Legacy file backed up to .enabled-services.backup"
    return 0
}

# Function: interactive_service_enablement
# Description: Provides interactive service selection interface
# Arguments: None
# Returns: 0 on success, 1 on failure
interactive_service_enablement() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🎛️  Interactive Service Enablement"
    echo "======================================"
    echo ""

    # Get all available services with their current enabled state
    echo "Available services:"

    local services=()
    local service_names=()
    local i=1

    # Build arrays of services and their info
    while IFS= read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')
        [ -z "$service_key" ] && continue

        services+=("$service_key")
        service_names+=("$service_key")

        local name enabled
        name=$(yq ".services[\"${service_key}\"].name" "$SERVICES_CONFIG" | tr -d '"')
        enabled=$(yq ".services[\"${service_key}\"].enabled" "$SERVICES_CONFIG")

        local status=""
        if [ "$enabled" = "true" ]; then
            status=" ✅"
        fi

        printf "  %2d. %-20s" "$i" "$service_key"
        [ "$name" != "null" ] && printf " - %s" "$name"
        printf "%s\n" "$status"

        i=$((i + 1))
    done < <(yq '.services | keys[]' "$SERVICES_CONFIG")

    echo ""
    echo "Enter the numbers of services to toggle (space-separated):"
    read -r -a selections

    # Process selections
    for num in "${selections[@]}"; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#services[@]}" ]; then
            local service="${services[$((num - 1))]}"
            local current_state
            current_state=$(yq ".services[\"${service}\"].enabled" "$SERVICES_CONFIG")

            if [ "$current_state" = "true" ]; then
                disable_services_via_yaml "$service"
            else
                enable_services_via_yaml "$service"
            fi
        else
            echo "⚠️  Invalid selection: $num"
        fi
    done

    echo ""
    echo "Current enabled services:"
    list_enabled_services_from_yaml

    return 0
}

# Function: list_available_services_from_config
# Description: Lists all available services from services.yaml with metadata
# Arguments: None
# Returns: 0 on success, 1 on failure
list_available_services_from_config() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "📋 Available services from configuration:"
    echo ""

    # Group services by category
    yq '.categories | keys[]' "$SERVICES_CONFIG" | while read -r category_key; do
        category_key=$(echo "$category_key" | tr -d '"')
        category_name=$(yq ".categories.${category_key}" "$SERVICES_CONFIG" | tr -d '"')

        echo "📁 $category_name ($category_key)"

        # Find services in this category
        yq '.services | to_entries[] | select(.value.category == "'"$category_key"'") | .key' "$SERVICES_CONFIG" | while read -r service_key; do
            service_key=$(echo "$service_key" | tr -d '"')
            service_name=$(yq ".services.${service_key}.name" "$SERVICES_CONFIG" | tr -d '"')
            service_desc=$(yq ".services.${service_key}.description" "$SERVICES_CONFIG" | tr -d '"')
            domain=$(yq ".services.${service_key}.domain" "$SERVICES_CONFIG" | tr -d '"')

            echo "  └── $service_key: $service_name"
            echo "      $service_desc"
            echo "      Domain: ${domain}.${BASE_DOMAIN:-\${BASE_DOMAIN\}}"
            echo ""
        done
    done

    return 0
}

# Function: validate_services_config
# Description: Validates the services.yaml configuration
# Arguments: None
# Returns: 0 if valid, 1 if invalid
validate_services_config() {
    if [ ! -f "$SERVICES_CONFIG" ]; then
        echo "❌ Error: Services configuration not found at $SERVICES_CONFIG"
        return 1
    fi

    echo "🔍 Validating services configuration..."

    # Check if it's valid YAML
    if ! yq '.' "$SERVICES_CONFIG" > /dev/null 2>&1; then
        echo "❌ Error: Invalid YAML syntax in $SERVICES_CONFIG"
        return 1
    fi

    # Check required top-level keys
    if ! yq '.version' "$SERVICES_CONFIG" > /dev/null 2>&1; then
        echo "❌ Error: Missing 'version' key in services configuration"
        return 1
    fi

    if ! yq '.services' "$SERVICES_CONFIG" > /dev/null 2>&1; then
        echo "❌ Error: Missing 'services' key in services configuration"
        return 1
    fi

    # Validate each service has required fields
    yq '.services | keys[]' "$SERVICES_CONFIG" | while read -r service_key; do
        service_key=$(echo "$service_key" | tr -d '"')

        # Check required fields
        for field in name description category domain compose; do
            if ! yq ".services.${service_key}.${field}" "$SERVICES_CONFIG" > /dev/null 2>&1; then
                echo "❌ Error: Service '$service_key' missing required field '$field'"
                return 1
            fi
        done
    done

    echo "✅ Services configuration is valid"
    return 0
}

# Note: Functions are available when script is sourced
