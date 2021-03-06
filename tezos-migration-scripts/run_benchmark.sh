#!/usr/bin/env bash
# Needs `moreutils` (for `ts`)

STORE_PRISTINE="/bench/craig/data/pristine/.tezos-node/"
STORE_DIRTY="/bench/craig/data/.tezos-node/"
TEZOS_NODE="src/bin_node/main.exe"
TEZOS_CLIENT="src/bin_client/main_client.exe"
WALLET="./yes-wallet"

if [[ ! -d "$WALLET" ]]; then
	echo "- Creating a noop Tezos wallet"
	dune exec scripts/yes-wallet/yes_wallet.exe create minimal in "$WALLET"
fi

if [[ ! -d "$STORE_PRISTINE" ]]; then
	echo "- Extracting a new pristine store from the archive"
	tar -I lz4 -xvf /bench/ngoguey/ro/migration_node_1month.tar.lz4 -C "$(basename $STORE_PRISTINE)"
fi

if [[ "$#" = 0 || "$1" != "--no-prepare" ]]; then
	echo "- Copying the pristine store to a fresh temporary location"
	rm -rf "$STORE_DIRTY"
	cp -r "$STORE_PRISTINE" "$STORE_DIRTY"

	echo "- Building the 'tezos-node' and 'tezos-client' binaries"
	dune build "./$TEZOS_NODE" "./$TEZOS_CLIENT"
else
	echo "- Skipping the preparation step as requested"
fi

random_unused_port () {
	comm -23 <(seq 49152 65535) <(ss -Htan | awk '{print $4}' | cut -d':' -f2 | sort -u) | shuf | head -n 1 || true
}

rpc_port=$(random_unused_port)
net_port=$(random_unused_port)

if [ -n "$TIME_DATA" ]; then
	time_output_node="--output=$TIME_DATA.node.data"
	time_output_client="--output=$TIME_DATA.client.data"
else
	time_output_node=""
	time_output_client=""
fi

echo "- Starting the 'tezos-node' process { rpc_port = $rpc_port; net_port = $net_port }"

/usr/bin/time $time_output_node -v "_build/default/$TEZOS_NODE" run \
	--data-dir "$STORE_DIRTY" \
	--private-mode \
	--no-bootstrap-peers \
	--net-addr localhost:$net_port \
	--rpc-addr localhost:$rpc_port \
	--connections 0 \
	--synchronisation-threshold 0 2>&1 | \
	ts "  [node]" &

sleep 5 # Give the node some time to start

# We want to kill `tezos-node` without killing the `time` parent process, so
# that we still get the data. We're getting the PID of `tezos-node` by looking
# up the port it's using.
node_pid="$(sudo ss -lp "sport = :$net_port" | grep -oP "pid=\K[0-9]*" | head -n 1)"

rm -f ./yes-wallet/blocks

/usr/bin/time $time_output -v "_build/default/$TEZOS_CLIENT" \
	--base-dir ./yes-wallet \
	--endpoint http://localhost:$rpc_port \
	bake for foundation1 2>&1 | \
	ts "[client]"

kill "$node_pid" && { while kill -0 "$node_pid" 2>/dev/null; do sleep 1; done; }
