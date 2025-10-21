#!/bin/bash

# Concord HTTP API Demo Script
# This script demonstrates various API endpoints with real examples

set -e

# Configuration
API_BASE="http://127.0.0.1:4002/api/v1"
TOKEN="demo_token_$(date +%s)"

echo "🚀 Concord HTTP API Demo"
echo "========================"
echo "API Base: $API_BASE"
echo ""

# Function to check if server is running
check_server() {
    echo "🔍 Checking if Concord server is running..."
    if curl -s "$API_BASE/health" > /dev/null; then
        echo "✅ Server is running!"
    else
        echo "❌ Server is not running. Please start Concord first:"
        echo "   CONCORD_API_PORT=4002 mix start"
        exit 1
    fi
    echo ""
}

# Function to make API calls with nice output
api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    local description=$4

    echo "📡 $description"
    echo "Request: $method $endpoint"

    if [ -n "$data" ]; then
        echo "Data: $data"
        response=$(curl -s -X "$method" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$API_BASE$endpoint")
    else
        response=$(curl -s -X "$method" "$API_BASE$endpoint")
    fi

    echo "Response:"
    echo "$response" | jq '.' 2>/dev/null || echo "$response"
    echo "--------"
    echo ""
}

# Demo functions
demo_health_check() {
    api_call "GET" "/health" "" "Health Check"
}

demo_openapi_spec() {
    echo "📚 OpenAPI Specification"
    echo "Available at: $API_BASE/openapi.json"
    echo "Swagger UI at: http://127.0.0.1:4002/api/docs"
    echo ""
}

demo_basic_operations() {
    echo "🔧 Basic CRUD Operations"
    echo "======================"

    # Store a simple value
    api_call "PUT" "/kv/demo:greeting" '{"value": "Hello from Concord API!"}' "Store greeting message"

    # Store JSON data with TTL
    api_call "PUT" "/kv/demo:user:123" '{"value": {"name": "Alice", "role": "admin", "last_login": "'$(date -Iseconds)'"}, "ttl": 300}' "Store user data with 5min TTL"

    # Retrieve the greeting
    api_call "GET" "/kv/demo:greeting" "" "Retrieve greeting message"

    # Retrieve user data with TTL
    api_call "GET" "/kv/demo:user:123?with_ttl=true" "" "Retrieve user data with TTL info"

    # List all keys
    api_call "GET" "/kv?limit=10" "" "List all keys (limit 10)"

    echo ""
}

demo_ttl_operations() {
    echo "⏰ TTL Operations"
    echo "================"

    # Get current TTL
    api_call "GET" "/kv/demo:user:123/ttl" "" "Get remaining TTL"

    # Extend TTL to 1 hour
    api_call "POST" "/kv/demo:user:123/touch" '{"ttl": 3600}' "Extend TTL to 1 hour"

    # Verify TTL was extended
    api_call "GET" "/kv/demo:user:123/ttl" "" "Verify TTL extension"

    echo ""
}

demo_bulk_operations() {
    echo "📦 Bulk Operations"
    echo "=================="

    # Bulk store multiple keys
    bulk_data='{
        "operations": [
            {"key": "demo:config:app", "value": {"debug": false, "version": "1.0.0", "port": 8080}},
            {"key": "demo:config:db", "value": {"host": "localhost", "port": 5432, "name": "myapp"}},
            {"key": "demo:feature:beta_ui", "value": true, "ttl": 600},
            {"key": "demo:counter:visits", "value": 42}
        ]
    }'
    api_call "POST" "/kv/bulk" "$bulk_data" "Bulk store configuration data"

    # Bulk retrieve multiple keys
    bulk_get='{"keys": ["demo:config:app", "demo:config:db", "demo:feature:beta_ui"], "with_ttl": true}'
    api_call "POST" "/kv/bulk/get" "$bulk_get" "Bulk retrieve configuration with TTL"

    # Bulk delete some keys
    bulk_delete='{"keys": ["demo:counter:visits", "demo:nonexistent"]}'
    api_call "POST" "/kv/bulk/delete" "$bulk_delete" "Bulk delete keys"

    echo ""
}

demo_error_handling() {
    echo "❌ Error Handling Examples"
    echo "=========================="

    # Try to access without auth (should fail if auth is enabled)
    echo "Attempting unauthenticated access..."
    if curl -s "$API_BASE/kv" | grep -q "UNAUTHORIZED"; then
        echo "✅ Authentication is working - unauthenticated request blocked"
    else
        echo "ℹ️  Authentication appears to be disabled in this configuration"
    fi
    echo ""

    # Try to get non-existent key
    api_call "GET" "/kv/demo:nonexistent" "" "Attempt to get non-existent key (404 expected)"

    # Try invalid key format
    api_call "PUT" "/kv/" '{"value": "test"}' "Attempt to use invalid key (400 expected)"

    # Try batch that's too large
    large_batch='{"operations": ['$(for i in {1..501}; do echo '{"key": "key'$i'", "value": "value'$i'"},'; done | sed 's/,$//')']}'
    echo "Attempting batch with 501 operations (limit is 500)..."
    response=$(curl -s -X POST -H "Content-Type: application/json" -d "$large_batch" "$API_BASE/kv/bulk")
    echo "$response" | jq '.' 2>/dev/null || echo "$response"
    echo "--------"
    echo ""
}

demo_advanced_usage() {
    echo "🎯 Advanced Usage Examples"
    echo "=========================="

    # Store nested configuration
    config_data='{
        "value": {
            "application": {
                "name": "Concord Demo App",
                "version": "1.2.3",
                "environment": "development"
            },
            "features": {
                "authentication": true,
                "rate_limiting": false,
                "analytics": true
            },
            "limits": {
                "max_requests_per_minute": 1000,
                "max_upload_size_mb": 10,
                "session_timeout_minutes": 30
            }
        },
        "ttl": 86400
    }'
    api_call "PUT" "/kv/demo:app:config" "$config_data" "Store comprehensive application configuration"

    # Update specific parts of configuration
    api_call "PUT" "/kv/demo:app:config:features" '{"value": {"authentication": true, "rate_limiting": true, "analytics": true}}' "Update feature flags"

    # Show cluster status
    api_call "GET" "/status" "" "Get cluster status and metrics"

    echo ""
}

cleanup_demo_data() {
    echo "🧹 Cleaning Up Demo Data"
    echo "========================="

    # List demo keys
    echo "Finding demo keys to clean up..."

    # Try to delete known demo keys
    demo_keys=(
        "demo:greeting"
        "demo:user:123"
        "demo:config:app"
        "demo:config:db"
        "demo:feature:beta_ui"
        "demo:app:config"
        "demo:app:config:features"
    )

    for key in "${demo_keys[@]}"; do
        echo "Deleting: $key"
        curl -s -X DELETE "$API_BASE/kv/$key" > /dev/null || true
    done

    echo "✅ Demo cleanup completed!"
    echo ""
}

# Main demo execution
main() {
    echo "Starting Concord HTTP API Demo..."
    echo ""

    # Check if jq is available for pretty JSON output
    if ! command -v jq &> /dev/null; then
        echo "⚠️  jq not found. Install jq for pretty JSON output:"
        echo "   Ubuntu/Debian: sudo apt install jq"
        echo "   macOS: brew install jq"
        echo ""
        echo "Continuing without pretty formatting..."
        echo ""
    fi

    check_server
    demo_health_check
    demo_openapi_spec
    demo_basic_operations
    demo_ttl_operations
    demo_bulk_operations
    demo_error_handling
    demo_advanced_usage

    echo "🎉 Demo completed successfully!"
    echo ""
    echo "📚 Learn more:"
    echo "   - Interactive API docs: http://127.0.0.1:4002/api/docs"
    echo "   - Usage examples: API_USAGE_EXAMPLES.md"
    echo "   - OpenAPI spec: $API_BASE/openapi.json"
    echo ""

    read -p "🧹 Clean up demo data? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_demo_data
    fi

    echo "✅ Demo finished! Thanks for trying Concord HTTP API!"
}

# Run the demo
main "$@"