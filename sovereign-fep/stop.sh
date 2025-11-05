#!/bin/bash
docker compose -f cdk-erigon.yaml down --remove-orphans
docker compose -f anvil.yaml down --remove-orphans
docker compose -f zkevm.yaml down --remove-orphans
rm -rf erigon-config
rm -rf data
rm -rf aggkit-oracle
rm -rf aggkit-bridge
rm -rf aggkit-sender
rm -rf zkevm-bridge
rm -rf aggkit-prover