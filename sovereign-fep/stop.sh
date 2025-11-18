#!/bin/bash
docker compose -f cdk-erigon.yaml down --remove-orphans
docker compose -f anvil.yaml down --remove-orphans
docker compose -f zkevm.yaml down --remove-orphans
docker compose -f reth.yaml down --remove-orphans
rm -rf erigon-config
rm -rf erigon-sequencer-config
rm -rf erigon-rpc-config
rm -rf sequencer-data
rm -rf rpc-data
rm -rf data
rm -rf aggkit-oracle
rm -rf aggkit-bridge
rm -rf aggkit-sender
rm -rf zkevm-bridge
rm -rf zkevm-postgres
rm -rf aggkit-prover
rm -rf reth-config
rm -rf reth-data
rm -rf engine-api-sync