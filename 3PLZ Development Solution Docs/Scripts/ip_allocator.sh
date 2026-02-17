#!/bin/bash

# Function: cidr_to_netmask
# Purpose: Converts a CIDR prefix length (e.g., 24) to a dotted decimal subnet mask (e.g., 255.255.255.0)
cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_bits=$((cidr % 8))

    for i in {1..4}; do
        if [ $i -le $full_octets ]; then
            mask+="255"
        elif [ $i -eq $((full_octets + 1)) ]; then
            mask+=$((256 - 2 ** (8 - partial_bits)))
        else
            mask+="0"
        fi
        [ $i -lt 4 ] && mask+="."
    done
    echo "$mask"
}

# Function: ip_to_int
# Purpose: Converts an IP address string to a 32-bit integer for arithmetic operations
ip_to_int() {
    local IFS=.
    read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Function: int_to_ip
# Purpose: Converts a 32-bit integer back to a dotted decimal IP address
int_to_ip() {
    local ip=$1
    echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
}

# Section: Argument Parsing
# Purpose: Parses command-line arguments for CIDR block (-a), allocation size (-o), expand flag (--expand), and DNS generation (-b)
EXPAND=false
GENERATE_DNS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a)
            CIDR_BLOCK="$2"
            shift 2
            ;;
        -o)
            ALLOC_SIZE="$2"
            shift 2
            ;;
        --expand)
            EXPAND=true
            shift
            ;;
        -b)
            GENERATE_DNS=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Section: Argument Validation
# Purpose: Ensures required arguments are provided before proceeding
if [ -z "$CIDR_BLOCK" ] || [ -z "$ALLOC_SIZE" ]; then
    echo "Usage: $0 -a <CIDR block> -o <allocation size> [--expand] [-b]"
    exit 1
fi

# Section: CIDR Block Setup
# Purpose: Extracts base IP and CIDR prefix from input and calculates block sizes
BASE_IP="${CIDR_BLOCK%/*}"
BASE_CIDR="${CIDR_BLOCK#*/}"
BASE_INT=$(ip_to_int "$BASE_IP")
BLOCK_SIZE=$((2 ** (32 - BASE_CIDR)))
ALLOC_SIZE_BLOCK=$((2 ** (32 - ALLOC_SIZE)))
SUBNET_MASK=$(cidr_to_netmask "$ALLOC_SIZE")

# Section: DNS File Preparation
# Purpose: Initializes empty forward and reverse DNS record files if DNS generation is enabled
if $GENERATE_DNS; then
    > forward_records.txt
    > reverse_records.txt
fi

# Section: Subnet Allocation Loop
# Purpose: Iterates over the CIDR block and allocates subnets based on the specified allocation size
NET_INDEX=0
for ((i=0; i<BLOCK_SIZE; i+=ALLOC_SIZE_BLOCK)); do
    SUBNET_BASE=$((BASE_INT + i))
    SUBNET_IP=$(int_to_ip "$SUBNET_BASE")

    # Section: Usable IP Allocation Loop
    # Purpose: Iterates over usable IPs in each subnet and prints allocation info
    for ((j=1; j<ALLOC_SIZE_BLOCK-1; j++)); do
        HOST_IP_INT=$((SUBNET_BASE + j))
        HOST_IP=$(int_to_ip "$HOST_IP_INT")
        echo "NET $NET_INDEX $SUBNET_IP $HOST_IP $SUBNET_MASK $HOST_IP/$ALLOC_SIZE"

        # Section: DNS Record Generation
        # Purpose: Generates pseudo hostnames and writes commented A and PTR records to DNS files
        if $GENERATE_DNS; then
            HOSTNAME="host-${HOST_IP//./-}"
            echo "# $HOSTNAME IN A $HOST_IP" >> forward_records.txt
            echo "# $(echo $HOST_IP | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa"}') IN PTR $HOSTNAME." >> reverse_records.txt
        fi

        [ "$EXPAND" = false ] && break
    done
    ((NET_INDEX++))
done
