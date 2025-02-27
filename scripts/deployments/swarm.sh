#!/bin/bash
swarm_create_ssl_secrets() {
    load_env

    echo "Creating swarm secrets for $BASE_DOMAIN"

    # Create Docker secrets from your existing cert files
    docker secret create "ssl_full.pem" "${PROJECT_ROOT}/certs/${BASE_DOMAIN}_ecc/fullchain.cer"
    docker secret create "ssl_key.pem" "${PROJECT_ROOT}/certs/${BASE_DOMAIN}_ecc/${BASE_DOMAIN}.key"
    docker secret create "ssl_ca.pem" "${PROJECT_ROOT}/certs/${BASE_DOMAIN}_ecc/ca.cer"
    docker secret create "ssl_dhparam.pem" "${PROJECT_ROOT}/certs/${BASE_DOMAIN}_ecc/dhparam.pem"
}


swarm_init() {
    echo "Initializing swarm on manager node..."
    
    # Get manager hostname
    MANAGER_HOST=$(machines_parse manager)
    MANAGER_IP=$(machines_get_host_ip "$MANAGER_HOST")
    
    echo "Resolved manager IP: $MANAGER_IP"
    
    # Initialize swarm
    docker swarm init --advertise-addr "$MANAGER_IP"
    docker swarm join-token -q worker > .swarm_token
}


# Initial setup of swarm cluster
swarm_setup() {
    # First ensure we have a token
    if [ ! -f .swarm_token ]; then
        echo "No swarm token found. Running swarm init first..."
        swarm_init
    fi
    
    # Create initial swarm secrets
    swarm_create_ssl_secrets
    
    # Sync nodes to match configuration
    swarm_sync_nodes
}

# Join a node to the swarm
swarm_join_node() {
    local host=$1
    local ip
    ip=$(machines_get_host_ip "$host")
    local token=$(cat .swarm_token)
    local manager_host=$(machines_parse manager)
    local manager_ip=$(machines_get_host_ip "$manager_host")
    
    echo "Joining node $host ($ip) to swarm..."
    ssh "$host" "docker swarm join --token $token ${manager_ip}:2377"
}

# Ongoing maintenance of swarm nodes
swarm_sync_nodes() {
    echo "Syncing swarm nodes with machines.yml configuration..."
    
    # Get current worker nodes from swarm
    current_nodes=$(docker node ls --format '{{.Hostname}}' | grep -v "$(machines_parse manager)")
    
    # Get desired worker nodes from machines.yml
    desired_nodes=$(machines_parse workers)
    
    # Remove nodes that shouldn't be there
    for node in $current_nodes; do
        if ! echo "$desired_nodes" | grep -q "$node"; then
            echo "Removing node $node from swarm..."
            docker node update --availability drain "$node"
            sleep 5  # Wait for services to drain
            docker node rm --force "$node"
            ssh "$node" "docker swarm leave --force"
        fi
    done
    
    # Add new nodes
    for node in $desired_nodes; do
        if ! docker node ls --format '{{.Hostname}}' | grep -q "$node"; then
            echo "Adding new node $node to swarm..."
            swarm_join_node "$node"
        fi
    done
    
    # Update labels
    for node in $desired_nodes; do
        echo "Updating labels for node $node..."
        # Remove existing labels
        current_labels=$(docker node inspect "$node" --format '{{range $k,$v := .Spec.Labels}}{{$k}}{{end}}')
        for label in $current_labels; do
            docker node update --label-rm "$label" "$node"
        done
        
        # Add new labels
        labels=$(machines_parse ".workers[] | select(.host == \"$node\") | .labels")
        if [ -n "$labels" ]; then
            for label in $labels; do
                docker node update --label-add "$label" "$node"
            done
        fi
    done
    
    echo "Swarm node sync complete."
    swarm_status
}

swarm_status() {
    echo "Swarm Nodes:"
    docker node ls
    
    echo -e "\nSwarm Services:"
    docker service ls
}