#!/bin/bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

source /opt/bash-utils/logger.sh

function wait_for_process () {
    local max_time_wait=30
    local process_name="$1"
    local waited_sec=0
    while ! pgrep "$process_name" >/dev/null && ((waited_sec < max_time_wait)); do
        INFO "Process $process_name is not running yet. Retrying in 1 seconds"
        INFO "Waited $waited_sec seconds of $max_time_wait seconds"
        sleep 1
        ((waited_sec=waited_sec+1))
        if ((waited_sec >= max_time_wait)); then
            return 1
        fi
    done
    return 0
}

# The following three functions are taken from https://github.com/docker-library/docker/blob/12a4554648b671111eaf4cf4636cb1d6310c65e1/dockerd-entrypoint.sh
# They are licensed under Apache License 2.0 https://github.com/docker-library/docker/blob/12a4554648b671111eaf4cf4636cb1d6310c65e1/LICENSE

_tls_ensure_private() {
	local f="$1"; shift
	[ -s "$f" ] || openssl genrsa -out "$f" 4096
}

_tls_san() {
	{
		ip -oneline address | awk '{ gsub(/\/.+$/, "", $4); print "IP:" $4 }'
		{
			cat /etc/hostname
			echo 'docker'
			echo 'localhost'
			hostname -f
			hostname -s
		} | sed 's/^/DNS:/'
		[ -z "${DOCKER_TLS_SAN:-}" ] || echo "$DOCKER_TLS_SAN"
	} | sort -u | xargs printf '%s,' | sed "s/,\$//"
}

_tls_generate_certs() {
	local dir="$1"; shift

	# if server/{ca,key,cert}.pem && !ca/key.pem, do NOTHING except verify (user likely managing CA themselves)
	# if ca/key.pem || !ca/cert.pem, generate CA public if necessary
	# if ca/key.pem, generate server public
	# if ca/key.pem, generate client public
	# (regenerating public certs every startup to account for SAN/IP changes and/or expiration)

	if [ -s "$dir/server/ca.pem" ] && [ -s "$dir/server/cert.pem" ] && [ -s "$dir/server/key.pem" ] && [ ! -s "$dir/ca/key.pem" ]; then
		openssl verify -CAfile "$dir/server/ca.pem" "$dir/server/cert.pem"
		return 0
	fi

	# https://github.com/FiloSottile/mkcert/issues/174
	local certValidDays='825'

	if [ -s "$dir/ca/key.pem" ] || [ ! -s "$dir/ca/cert.pem" ]; then
		# if we either have a CA private key or do *not* have a CA public key, then we should create/manage the CA
		mkdir -p "$dir/ca"
		_tls_ensure_private "$dir/ca/key.pem"
		openssl req -new -key "$dir/ca/key.pem" \
			-out "$dir/ca/cert.pem" \
			-subj '/CN=docker:dind CA' -x509 -days "$certValidDays"
	fi

	if [ -s "$dir/ca/key.pem" ]; then
		# if we have a CA private key, we should create/manage a server key
		mkdir -p "$dir/server"
		_tls_ensure_private "$dir/server/key.pem"
		openssl req -new -key "$dir/server/key.pem" \
			-out "$dir/server/csr.pem" \
			-subj '/CN=docker:dind server'
		cat > "$dir/server/openssl.cnf" <<-EOF
			[ x509_exts ]
			subjectAltName = $(_tls_san)
		EOF
		openssl x509 -req \
				-in "$dir/server/csr.pem" \
				-CA "$dir/ca/cert.pem" \
				-CAkey "$dir/ca/key.pem" \
				-CAcreateserial \
				-out "$dir/server/cert.pem" \
				-days "$certValidDays" \
				-extfile "$dir/server/openssl.cnf" \
				-extensions x509_exts
		cp "$dir/ca/cert.pem" "$dir/server/ca.pem"
		openssl verify -CAfile "$dir/server/ca.pem" "$dir/server/cert.pem"
	fi

	if [ -s "$dir/ca/key.pem" ]; then
		# if we have a CA private key, we should create/manage a client key
		mkdir -p "$dir/client"
		_tls_ensure_private "$dir/client/key.pem"
		chmod 0644 "$dir/client/key.pem" # openssl defaults to 0600 for the private key, but this one needs to be shared with arbitrary client contexts
		openssl req -new \
				-key "$dir/client/key.pem" \
				-out "$dir/client/csr.pem" \
				-subj '/CN=docker:dind client'
		cat > "$dir/client/openssl.cnf" <<-'EOF'
			[ x509_exts ]
			extendedKeyUsage = clientAuth
		EOF
		openssl x509 -req \
				-in "$dir/client/csr.pem" \
				-CA "$dir/ca/cert.pem" \
				-CAkey "$dir/ca/key.pem" \
				-CAcreateserial \
				-out "$dir/client/cert.pem" \
				-days "$certValidDays" \
				-extfile "$dir/client/openssl.cnf" \
				-extensions x509_exts
		cp "$dir/ca/cert.pem" "$dir/client/ca.pem"
		openssl verify -CAfile "$dir/client/ca.pem" "$dir/client/cert.pem"
	fi
}

INFO "Generating certs"
_tls_generate_certs $DOCKER_TLS_CERTDIR

INFO "Starting supervisor"
/usr/bin/dockerd \
    --host=unix:///var/run/docker.sock \
    --host=tcp://0.0.0.0:2376 \
    --tlsverify \
    --tlscacert $DOCKER_TLS_CERTDIR/server/ca.pem \
    --tlscert  $DOCKER_TLS_CERTDIR/server/cert.pem \
    --tlskey  $DOCKER_TLS_CERTDIR/server/key.pem
