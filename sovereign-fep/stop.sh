#!/bin/bash
docker compose -f cdk-erigon.yaml down --remove-orphans
docker compose -f anvil.yaml down --remove-orphans
rm -rf erigon-config
rm -rf data