#!/bin/bash

# Function to show usage
usage() {
    echo "Usage: $0 -u <username> -d <user_directory> [-m <user@domain.com>]"
    exit 1
}

# Parse command-line arguments
while getopts ":u:d:m:" opt; do
  case $opt in
    u) USERNAME="$OPTARG" ;;
    d) USERDIR="$OPTARG" ;;
    m) EMAIL="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG" >&2
        usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2
       usage ;;
  esac
done

# Check required arguments
if [ -z "$USERNAME" ] || [ -z "$USERDIR" ]; then
    usage
fi

# Define SSH directory and log file
SSH_DIR="$USERDIR/.ssh"
LOG_FILE="$SSH_DIR/keygen.log"

# Ensure SSH directory exists
mkdir -p "$SSH_DIR"
chown "$USERNAME":"$USERNAME" "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Rotate log if older than 30 days
if [ -f "$LOG_FILE" ]; then
    if [ $(find "$LOG_FILE" -mtime +30) ]; then
        mv "$LOG_FILE" "$LOG_FILE.$(date +%Y%m%d)"
        touch "$LOG_FILE"
    fi
fi

# Remove old keys
rm -f "$SSH_DIR/id_rsa" "$SSH_DIR/id_rsa.pub"

# Generate new SSH key pair
sudo -u "$USERNAME" ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N ""
if [ $? -ne 0 ]; then
    echo "Error: SSH key generation failed for user '$USERNAME'."
    exit 3
fi

# Set appropriate permissions
chmod 600 "$SSH_DIR/id_rsa"
chmod 644 "$SSH_DIR/id_rsa.pub"

echo "New SSH keys generated for user '$USERNAME' in '$SSH_DIR'."

# Get public key fingerprint
FINGERPRINT=$(ssh-keygen -lf "$SSH_DIR/id_rsa.pub" | awk '{print $2}')

# Email the scrambled private key if requested
if [ -n "$EMAIL" ]; then
    if command -v mailx >/dev/null 2>&1; then
        # Generate a random 12-character alphanumeric string
        PASSPHRASE=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

        # Scramble the private key using openssl enc
        SCRAMBLED_FILE=$(mktemp)
        openssl enc -aes-256-cbc -salt -in "$SSH_DIR/id_rsa" -out "$SCRAMBLED_FILE" -pass pass:"$PASSPHRASE"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to scramble the private key."
            rm -f "$SCRAMBLED_FILE"
            exit 4
        fi

        # Compose email body with instructions
        EMAIL_BODY=$(cat <<EOF
Your SSH private key has been securely scrambled using AES-256 encryption.

To unscramble it, save the attached content to a file (e.g., scrambled_key.enc) and run the following command:

openssl enc -d -aes-256-cbc -in scrambled_key.enc -out id_rsa -pass pass:$PASSPHRASE

This will produce your usable private key file named 'id_rsa'.

Please keep this passphrase secure: $PASSPHRASE

Do not share this passphrase or the key file with anyone you do not trust.

Public Key Fingerprint: $FINGERPRINT
EOF
)

        # Send instructions
        echo "$EMAIL_BODY" | mailx -s "Your scrambled SSH private key and instructions" "$EMAIL"

        # Send scrambled key as attachment
        uuencode "$SCRAMBLED_FILE" scrambled_key.enc | mailx -s "Attachment: Scrambled SSH Key" "$EMAIL"

        echo "Scrambled private key and instructions emailed to $EMAIL."
        rm -f "$SCRAMBLED_FILE"

        # Log the key generation event
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$TIMESTAMP] Key generated for user '$USERNAME' | Fingerprint: $FINGERPRINT | Scramble passphrase: $PASSPHRASE | Sent to: $EMAIL" >> "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    else
        echo "Error: 'mailx' is not installed. Cannot send email."
        exit 2
    fi
fi
