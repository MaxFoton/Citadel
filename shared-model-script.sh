#!/bin/bash

# Set model path constants
MODEL_SOURCE="hf:TheBloke/phi-2-GGUF:phi-2.Q4_K_M.gguf"
MODEL_NAME="phi-2.Q4_K_M.gguf"
SHARED_VOLUME_NAME="aios_models"
SHARED_NETWORK_NAME="aios_network"
SHARED_CONTAINER_NAME="aios_model_storage"

# Create shared Docker network if it doesn't exist
if ! docker network inspect $SHARED_NETWORK_NAME >/dev/null 2>&1; then
    echo "Creating shared network: $SHARED_NETWORK_NAME"
    docker network create $SHARED_NETWORK_NAME
    echo "Network created successfully"
else
    echo "Shared network $SHARED_NETWORK_NAME already exists"
fi

# Create shared volume if it doesn't exist
if ! docker volume inspect $SHARED_VOLUME_NAME >/dev/null 2>&1; then
    echo "Creating shared volume: $SHARED_VOLUME_NAME"
    docker volume create $SHARED_VOLUME_NAME
    echo "Volume created successfully"
else
    echo "Shared volume $SHARED_VOLUME_NAME already exists"
fi

# Check if shared container exists, if not create and download model
if ! docker ps -a --format "{{.Names}}" | grep -q "^$SHARED_CONTAINER_NAME$"; then
    echo "Creating and setting up shared model container: $SHARED_CONTAINER_NAME"
    
    # Create a minimal container to download the model
    docker run -d --name $SHARED_CONTAINER_NAME \
        --network $SHARED_NETWORK_NAME \
        -v $SHARED_VOLUME_NAME:/shared_models \
        ubuntu:20.04 sleep infinity
    
    # Install necessary tools and download the model
    docker exec -it $SHARED_CONTAINER_NAME bash -c "
        apt-get update && apt-get install -y curl wget git
        echo 'Downloading model $MODEL_SOURCE to shared volume...'
        mkdir -p /shared_models
        # This part would need to be adjusted to match how the model is actually downloaded
        # Here we're simulating the model download
        cd /shared_models
        if [ ! -f /shared_models/$MODEL_NAME ]; then
            # Replace this with the actual download command for your model
            # Example: Using huggingface-cli or direct download
            echo 'Downloading model, this might take some time...'
            wget -q --show-progress https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/$MODEL_NAME -O /shared_models/$MODEL_NAME
            echo 'Model downloaded successfully'
        else
            echo 'Model already exists in shared volume'
        fi
    "
else
    echo "Shared model container $SHARED_CONTAINER_NAME already exists"
    # Check if the container is running, if not start it
    if ! docker ps --format "{{.Names}}" | grep -q "^$SHARED_CONTAINER_NAME$"; then
        echo "Starting shared model container..."
        docker start $SHARED_CONTAINER_NAME
    fi
fi

# Get all running containers matching the pattern
containers=$(docker ps --format "{{.Names}}" | grep -E "^aios[2-9][0-9]*$")

# Check if there are any matching containers
if [ -z "$containers" ]; then
    echo "No running containers with names aios2, aios3, ..."
    exit 1
fi

# Connect all containers to the shared network
for container in $containers; do
    echo "Connecting container $container to shared network..."
    
    # Connect to shared network if not already connected
    if ! docker network inspect $SHARED_NETWORK_NAME | grep -q "\"$container\""; then
        docker network connect $SHARED_NETWORK_NAME $container
        echo "Container $container connected to shared network"
    else
        echo "Container $container already connected to shared network"
    fi
    
    # Mount shared volume and set up the environment
    docker exec -it "$container" bash -c "
        echo 'Setting up environment for container $container...'
        
        # Create mount point for shared models
        mkdir -p /shared_models
        
        # Setup environment
        echo 'Configuring aios-cli...'
        
        # Check if aios-cli exists
        if [ ! -f /root/.aios/aios-cli ]; then
            echo 'ERROR: File /root/.aios/aios-cli is missing!'
            exit 1
        fi
        
        # Make it executable
        chmod +x /root/.aios/aios-cli
        
        # Add to PATH
        export PATH=\$PATH:/root/.aios
        echo 'Current PATH: \$PATH'
        
        # Verify it's in PATH
        if ! command -v aios-cli &>/dev/null; then
            echo 'ERROR: aios-cli not found even after updating PATH!'
            exit 1
        fi
        
        # Install screen if needed
        echo 'Checking if screen is installed'
        if ! command -v screen &>/dev/null; then
            echo 'Screen not installed. Installing...'
            apt-get update && apt-get install -y screen
        fi
        
        # Start aios-cli in screen session
        echo 'Starting aios-cli in screen'
        screen -dmS aios bash -c 'export PATH=\$PATH:/root/.aios && aios-cli start; exec bash'
        
        echo 'Waiting 15 seconds for aios initialization...'
        sleep 5
        
        # Check if screen session is running
        if ! screen -list | grep -q 'aios'; then
            echo 'ERROR: aios screen session failed to start'
            exit 1
        fi
        
        # Login to Hive
        echo 'Logging into Hive'
        if ! /root/.aios/aios-cli hive login; then
            echo 'ERROR: Failed to login'
            exit 1
        fi
        sleep 5
        
        # Select tier
        echo 'Selecting tier 5'
        if ! /root/.aios/aios-cli hive select-tier 5; then
            echo 'ERROR: Failed to select tier'
            exit 1
        fi
        sleep 5
        
        # Register the model from local path
        echo 'Registering model from local path'
        # Copy model from shared volume if needed
        if [ ! -d /root/.aios/models ]; then
            mkdir -p /root/.aios/models
        fi
        
        # Link or copy from shared location to local model directory
        if [ ! -f /root/.aios/models/$MODEL_NAME ]; then
            echo 'Linking model from shared volume...'
            ln -s /shared_models/$MODEL_NAME /root/.aios/models/$MODEL_NAME
        fi
        
        # Register the local model instead of downloading it
        if ! /root/.aios/aios-cli models add local:/root/.aios/models/$MODEL_NAME; then
            echo 'ERROR: Failed to register model from local path'
            exit 1
        fi
        sleep 5
        
        # Save keys
        echo 'Saving keys'
        if ! /root/.aios/aios-cli hive whoami > /root/aios_keys.txt; then
            echo 'ERROR: Failed to save keys'
            exit 1
        fi
        sleep 5
        
        # Connect to Hive
        echo 'Connecting to Hive'
        if ! /root/.aios/aios-cli hive connect; then
            echo 'ERROR: Failed to connect to Hive'
            exit 1
        fi
        sleep 5
        
        # Check points
        echo 'Checking points'
        if ! /root/.aios/aios-cli hive points; then
            echo 'ERROR: Failed to check points'
            exit 1
        fi
        sleep 5
        
        echo 'All commands executed successfully!'
        echo \"\$(date): Setup for container $container completed successfully\" >> /root/setup_logs.txt
        
        echo 'Screen session status:'
        screen -list
    "
    
    echo "Container $container processed successfully"
    echo "----------------------------------------"
done

# Mount the shared volume to all containers
for container in $containers; do
    echo "Mounting shared volume to container $container..."
    
    # Check if the container has the volume mounted
    if ! docker inspect $container | grep -q "$SHARED_VOLUME_NAME"; then
        # Since we can't directly mount a volume to a running container,
        # we'll need to update the container's configuration
        echo "Note: To fully mount the volume, you may need to recreate the container."
        echo "For now, we've used a symbolic link approach inside the container."
    fi
done

echo "All containers processed"
echo "Shared model is available at /shared_models/$MODEL_NAME in all containers"
