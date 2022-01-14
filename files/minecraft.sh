#!/bin/bash

rcon() {
  HOST=localhost
  PORT=25575
  COMMAND=$1
  reverse-hex-endian () {
    # Given a 4-byte hex integer, reverse endianness
    while read -r -d '' -N 8 INTEGER; do
      echo "$INTEGER" | sed -E 's/(..)(..)(..)(..)/\4\3\2\1/'
    done
  }

  decode-hex-int () {
    # decode little-endian hex integer
    while read -r -d '' -N 8 INTEGER; do
      BIG_ENDIAN_HEX=$(echo "$INTEGER" | reverse-hex-endian)
      echo "$((16#$BIG_ENDIAN_HEX))"
    done
  }

  stream-to-hex () {
    xxd -ps
  }

  hex-to-stream () {
    xxd -ps -r
  }

  encode-int () {
    # Encode an integer as 4 bytes in little endian and return as hex
    INT="$1"
    # Source: https://stackoverflow.com/a/9955198
    printf "%08x" "$INT" | sed -E 's/(..)(..)(..)(..)/\4\3\2\1/'
  }

  encode () {
    # Encode a packet type and payload for the rcon protocol
    TYPE="$1"
    PAYLOAD="$2"
    REQUEST_ID="$3"
    PAYLOAD_LENGTH="${#PAYLOAD}"
    TOTAL_LENGTH="$((4 + 4 + PAYLOAD_LENGTH + 1 + 1))"

    OUTPUT=""
    OUTPUT+=$(encode-int "$TOTAL_LENGTH")
    OUTPUT+=$(encode-int "$REQUEST_ID")
    OUTPUT+=$(encode-int "$TYPE")
    OUTPUT+=$(echo -n "$PAYLOAD" | stream-to-hex)
    OUTPUT+="0000"

    echo -n "$OUTPUT" | hex-to-stream
  }

  read-response () {
    # read next response packet and return the payload text
    HEX_LENGTH=$(head -c4 <&3 | stream-to-hex | reverse-hex-endian)
    LENGTH=$((16#$HEX_LENGTH))

    RESPONSE_PAYLOAD=$(head -c $LENGTH <&3 | stream-to-hex)
    echo -n "$RESPONSE_PAYLOAD"
  }

  response-request-id () {
    echo -n "${1:0:8}" | decode-hex-int
  }

  response-type () {
    echo -n "${1:8:8}" | decode-hex-int
  }

  response-payload () {
    echo -n "${1:16:-4}" | hex-to-stream
  }

  login () {
    PASSWORD="$1"
    encode 3 "$PASSWORD" 12 >&3
    RESPONSE=$(read-response "$IN_PIPE")
    RESPONSE_REQUEST_ID=$(response-request-id "$RESPONSE")
    if [[ "$RESPONSE_REQUEST_ID" == "-1" ]] || [[ "$RESPONSE_REQUEST_ID" == "4294967295" ]]; then
      echo "RCON connection failed: Wrong RCON password"
      return 1
    fi
  }

  run-command () {
    COMMAND="$1"
    # encode 2 "$COMMAND" 13 >> "$OUT_PIPE"
    encode 2 "$COMMAND" 13 >&3
    RESPONSE=$(read-response "$IN_PIPE")
    response-payload "$RESPONSE"
  }

  # Open a TCP socket
  # Source: https://www.xmodulo.com/tcp-udp-socket-bash-shell.html
  if ! exec 3<>/dev/tcp/"$HOST"/"$PORT"; then
    log-warning "RCON connection failed: Could not connect to $HOST:$PORT"
    return 1
  fi

  login "$PASSWORD" || return 1
  debug-log "$(run-command "$COMMAND")"

  # Close the socket
  exec 3<&-
  exec 3>&-
}

backup() {
  PASSWORD=$1
  ARCHIVE="$(date +%F_%H-%M-%S).tar.gz"
  rcon "tellraw @a [\"\",{\"text\":\"[Backup] \",\"color\":\"gray\",\"italic\":true},{\"text\":\"Starting backup\",\"color\":\"gray\",\"italic\":true}}}]"
  rcon "save-off"
  tar cfz $ARCHIVE world
  gclone rclone copy $ARCHIVE gdrive:backup
  rm -f $ARCHIVE
}

case $1 in
  backup) backup $2;;
esac