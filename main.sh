#!/bin/bash

# ====== LOGGING FUNCTION ======
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ====== SETUP ======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/logs/upload.log"

# Create logs directory if it doesn't exist
mkdir -p "$SCRIPT_DIR/logs"

log "🚀 Starting S3 upload script..."
log "🔧 Loading environment variables..."

# Load .env file if it exists
if [[ -f "$ENV_FILE" ]]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
    log "✅ Environment variables loaded from .env file."
else
    log "ℹ️ No .env file found. Using environment variables from shell."
fi

# ====== DEBUG: PRINT ENVIRONMENT VARIABLES (SAFELY) ======
log "🔍 DEBUG: Checking environment variables..."
log "AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:10}..."
log "AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:0:10}..."
log "AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}"
log "S3_BUCKET: ${S3_BUCKET}"

# ====== VALIDATE REQUIRED VARIABLES ======
required_vars=(
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY" 
    "AWS_DEFAULT_REGION"
    "S3_BUCKET"
)

SOURCE_DIR="${SOURCE_DIR:-$SCRIPT_DIR/files}"
S3_PREFIX="${S3_PREFIX:-uploads}"
VERIFY_UPLOAD="${VERIFY_UPLOAD:-true}"

for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        log "❌ ERROR: Missing $var environment variable"
        exit 1
    fi
done

log "✅ All required environment variables are set."

# ====== CHECK AWS CLI ======
if ! command -v aws &> /dev/null; then
    log "❌ ERROR: AWS CLI not installed. Please install it first."
    exit 1
fi

log "🔍 AWS CLI version:"
aws --version

log "🔍 AWS configuration check:"
aws configure list

# ====== VERIFY AWS CREDENTIALS ======
log "🔐 Verifying AWS credentials..."
aws_test_output=$(aws sts get-caller-identity 2>&1)
aws_test_exit_code=$?

if [[ $aws_test_exit_code -eq 0 ]]; then
    log "✅ AWS credentials verified successfully."
    log "🔍 AWS Identity: $aws_test_output"
else
    log "❌ ERROR: AWS credentials test failed with exit code: $aws_test_exit_code"
    log "❌ AWS Error Output: $aws_test_output"
    exit 1
fi

# ====== CHECK SOURCE DIRECTORY ======
if [[ ! -d "$SOURCE_DIR" ]]; then
    log "❌ ERROR: SOURCE_DIR '$SOURCE_DIR' does not exist."
    exit 1
fi

if [[ -z "$(ls -A "$SOURCE_DIR")" ]]; then
    log "❌ ERROR: SOURCE_DIR '$SOURCE_DIR' is empty. Nothing to upload."
    exit 1
fi

# ====== PREPARE S3 DESTINATION ======
timestamp=$(date +%Y%m%d_%H%M%S)
s3_prefix="${S3_PREFIX}/${timestamp}"
s3_destination="s3://${S3_BUCKET}/${s3_prefix}"

log "📂 Source: $SOURCE_DIR"
log "☁️ Destination: $s3_destination"
file_count=$(find "$SOURCE_DIR" -type f | wc -l)
log "📄 Files to upload: $file_count"

# ====== TEST S3 BUCKET ACCESS ======
log "🔍 Testing S3 bucket access..."
if aws s3api head-bucket --bucket "${S3_BUCKET}" &> /dev/null; then
    log "✅ S3 bucket access confirmed."
else
    log "❌ ERROR: Cannot access S3 bucket: ${S3_BUCKET}"
    log "🔍 Buckets you have access to:"
    aws s3 ls
    exit 1
fi

# ====== CHECK ZIP TOOL ======
if ! command -v zip &> /dev/null; then
    log "❌ ERROR: zip command not found. Please install zip utility."
    exit 1
fi
log "✅ zip utility found."

# Add pv check after zip check:
if ! command -v pv &> /dev/null; then
    log "⚠️  WARNING: pv not found. Install with: apt-get install pv"
    exit 1
fi
log "✅ pv utility found."

# ====== UPLOAD TO S3 ======
log "⬆️ Uploading files..."

upload_failed=0
MIN_FILE_AGE_DAYS="${MIN_FILE_AGE_DAYS:-10}"  # Default to 10 days if not set
TEMP_DIR="${TEMP_DIR:-/tmp}"
MAX_BANDWIDTH="${MAX_BANDWIDTH:-2Mb/s}"

# Find all files, sort by creation time (oldest first), and upload one by one
while IFS= read -r file_path; do
    # Get relative path for S3 destination
    rel_path="${file_path#$SOURCE_DIR/}"
    filename=$(basename "$file_path")
    file_dir=$(dirname "$file_path")

    # Create zip filename (use original filename with .zip extension)
    zip_filename="${filename}.zip"
    zip_path="${TEMP_DIR}/${zip_filename}"

    # S3 destination path for the zip file
    s3_zip_path="${s3_destination}/${rel_path}.zip"

    log "📦 Zipping: $rel_path"

    # Create zip file containing only this file
    # Change to file's directory to preserve relative structure in zip
    cd "$file_dir" || exit 1

    if zip "$zip_path" "$filename" -q 2>&1; then
        cd - > /dev/null || true
        zip_size=$(du -h "$zip_path" | cut -f1)
        log "✅ Zip created: $zip_filename (size: $zip_size)"

        log "📤 Uploading zip: $zip_filename"
        file_size=$(stat -c%s "$zip_path" 2>/dev/null || stat -f%z "$zip_path" 2>/dev/null)

        if pv -L "${MAX_BANDWIDTH}" -s "$file_size" "$zip_path" | aws s3 cp - "$s3_zip_path" --storage-class STANDARD_IA 2>&1 | tee -a "$LOG_FILE"; then
            log "✅ Uploaded zip: $zip_filename (throttled to ${MAX_BANDWIDTH})"

            # Clean up zip file after successful upload
            rm -f "$zip_path"
            log "🗑️ Temporary zip deleted: $zip_filename"

            # Check file age and delete original file if old enough
            file_age_days=$(( ($(date +%s) - $(stat -c %Y "$file_path")) / 86400 ))
            if [[ $file_age_days -ge $MIN_FILE_AGE_DAYS ]]; then
                rm -f "$file_path"
                log "🗑️ Deleted original file: $rel_path (age: ${file_age_days} days)"
            else
                log "⏳ Skipped deletion: $rel_path (age: ${file_age_days} days, must be >${MIN_FILE_AGE_DAYS} days old)"
            fi
        else
            log "❌ Failed to upload zip: $zip_filename"
            rm -f "$zip_path"  # Clean up zip on upload failure
            upload_failed=1
        fi
    else
        cd - > /dev/null || true
        log "❌ Failed to create zip: $zip_filename"
        upload_failed=1
    fi
done < <(find "$SOURCE_DIR" -type f -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)