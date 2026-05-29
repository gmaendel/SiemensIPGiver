#!/bin/sh
set -eu

BPF_GROUP="siemensipgiver-bpf"

if ! /usr/bin/dscl . -read "/Groups/${BPF_GROUP}" >/dev/null 2>&1; then
	/usr/sbin/dseditgroup -q -o create "${BPF_GROUP}"
fi

for device in /dev/bpf*; do
	if [ -e "${device}" ]; then
		/bin/chgrp "${BPF_GROUP}" "${device}" || true
		/bin/chmod g+rw "${device}" || true
	fi
done

exit 0
