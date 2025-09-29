#!/bin/bash
#
# to use this script you will need the following installed:
# node, npm, docker, docker-compose, cast, jq, sed, git
#
#

pwd=$(pwd)
l1_rpc_url="http://localhost:8545"
mnemonic="test test test test test test test test test test test junk"

anvil_key="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

admin_key=0xac33ceb856fbc1df24f1850c3ddd1a7cc5a1bea3aa94c45abc6d44cd8dccfeef
admin_address=0xEB722eCe6D7028cA72Ca98Cb324cc22Da83e1d20

sequencer_key=0xd828fe23d9d8e92aa1c92ad2b7e172a9c35608d42d114068abd7bb2da98c38cd
sequencer_address=0x0318A80977AcEF01302CA8911164d597cE5804a4

aggregator_key=0xdf7cfe586c4c20f5a9d605e6557baf33f0c341f451b1cfeaf901f4602fd54c9b
aggregator_address=0xB420ffDfBf6e54b8aB2B528Fbcf941246583b9B8

# start anvil running so we have our L1
docker compose -f anvil.yaml up -d

until cast send --rpc-url "$l1_rpc_url" --private-key "$anvil_key" --value 0 "0x0000000000000000000000000000000000000001" &> /dev/null; do
    echo "Waiting for L1 RPC..."
    sleep 2
done

# Fund your deployment accounts
cast send --rpc-url "$l1_rpc_url" --private-key "$anvil_key" --value "100ether" "$admin_address"
cast send --rpc-url "$l1_rpc_url" --private-key "$anvil_key" --value "100ether" "$sequencer_address"
cast send --rpc-url "$l1_rpc_url" --private-key "$anvil_key" --value "100ether" "$aggregator_address"

# launch the cdk contracts onto the L1
if [ ! -d "agglayer-contracts" ]; then
        git clone git@github.com:agglayer/agglayer-contracts.git
fi
cp deploy_parameters.json agglayer-contracts/deployment/v2/deploy_parameters.json
cp create_rollup_parameters.json agglayer-contracts/deployment/v2/create_rollup_parameters.json

cd agglayer-contracts
git checkout 2488a0812dd64f622b4890fee14c3b8938bb76df
npm i 
npx hardhat compile

echo "[contracts] Step 1: Preparing testnet"
npx hardhat run deployment/testnet/prepareTestnet.ts --network localhost 2>&1 | tee 01_prepare_testnet.out
echo "[contracts] Step 1: Done"

echo "[contracts] Step 2: Deploying PolygonZKEVMDeployer"
npx hardhat run deployment/v2/2_deployPolygonZKEVMDeployer.ts --network localhost 2>&1 | tee 02_zkevm_deployer.out
echo "[contracts] Step 2: Done"

echo "[contracts] Step 3: Deploying core contracts"
npx hardhat run deployment/v2/3_deployContracts.ts --network localhost 2>&1 | tee 03_deploy_contracts.out
echo "[contracts] Step 3: Done"

echo "[contracts] Step 4: Creating genesis"
MNEMONIC="$mnemonic" npx ts-node deployment/v2/1_createGenesis.ts 2>&1 | tee 04_create_genesis.out
echo "[contracts] Step 4: Done"

echo "[contracts] Step 5: Creating rollup"
npx hardhat run deployment/v2/4_createRollup.ts --network localhost 2>&1 | tee 05_create_rollup.out
echo "[contracts] Step 5: Done"

# Deploy deterministic deployment proxy (for CREATE2 deployments)
echo "[contracts] Step 6: Deploying deterministic deployment proxy"
signer_address="0x3fab184622dc19b6109349b94811493bf2a45362"
transaction="0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222"
deployer_address="0x4e59b44847b379578588920ca78fbf26c0b4956c"
cast send --rpc-url "$l1_rpc_url" --private-key "$anvil_key" --value "0.1ether" "$signer_address"
cast publish --rpc-url "$l1_rpc_url" "$transaction"
if [[ $(cast code --rpc-url $l1_rpc_url $deployer_address) == "0x" ]]; then
    echo "No code at deployer address: $deployer_address"
    exit 1
fi
echo "[contracts] Step 6: Done"

# Grant aggregator role to agglayer (if needed)
echo "[contracts] Step 6: Granting aggregator role to agglayer"
rollup_manager=$(jq -r '.polygonRollupManagerAddress' deployment/v2/deploy_output.json)
cast send \
    --private-key "$admin_key" \
    --rpc-url "$l1_rpc_url" \
    "$rollup_manager" \
    'grantRole(bytes32,address)' \
    "0x084e94f375e9d647f87f5b2ceffba1e062c70f6009fdbcf80291e803b5c9edd4" \
    "$aggregator_address"
echo "[contracts] Step 6: Done"

echo "[contracts] Step 7: Minting POL tokens for sequencer and adding approval for rollup"
# Mint POL tokens for sequencer
pol_token=$(jq -r '.polTokenAddress' deployment/v2/deploy_output.json)
cast send \
    --private-key "$sequencer_key" \
    --rpc-url "$l1_rpc_url" \
    "$pol_token" \
    'mint(address,uint256)' \
    "$sequencer_address" \
    "1000000000000000000000000000"

address_zkevm=$(jq -r '.rollupAddress' deployment/v2/create_rollup_output.json)

cast send \
    --private-key "$sequencer_key" \
    --legacy \
    --rpc-url "$l1_rpc_url" \
    "$pol_token" \
    'approve(address,uint256)(bool)' \
    "$address_zkevm" 1000000000000000000000000000
echo "[contracts] Step 7: Done"

# now we can begin to launch the rollup itself
cd $pwd
echo "[rollup] Step 1: Creating configs"
# erigon config
mkdir -p erigon-config
cp base-dynamic-network-config.yaml erigon-config/dynamic-network-config.yaml

sed -i '' "s/zkevm.address-sequencer: .*/zkevm.address-sequencer: $sequencer_address/" erigon-config/dynamic-network-config.yaml

address_zkevm=$(jq -r '.rollupAddress' ./agglayer-contracts/deployment/v2/create_rollup_output.json)
sed -i '' "s/zkevm.address-zkevm: .*/zkevm.address-zkevm: $address_zkevm/" erigon-config/dynamic-network-config.yaml

address_rollup=$(jq -r '.polygonRollupManagerAddress' ./agglayer-contracts/deployment/v2/deploy_output.json)
sed -i '' "s/zkevm.address-rollup: .*/zkevm.address-rollup: $address_rollup/" erigon-config/dynamic-network-config.yaml

address_ger=$(jq -r '.polygonZkEVMGlobalExitRootAddress' ./agglayer-contracts/deployment/v2/deploy_output.json)
sed -i '' "s/zkevm.address-ger-manager: .*/zkevm.address-ger-manager: $address_ger/" erigon-config/dynamic-network-config.yaml

# conf file
cp base-dynamic-network-conf.json erigon-config/dynamic-network-conf.json
root=$(jq -r '.genesis' ./agglayer-contracts/deployment/v2/create_rollup_output.json)
sed -i '' "s/\"root\": .*/\"root\": \"$root\",/" erigon-config/dynamic-network-conf.json

timestamp=$(jq -r '.firstBatchData.timestamp' ./agglayer-contracts/deployment/v2/create_rollup_output.json)
sed -i '' "s/\"timestamp\": .*/\"timestamp\": $timestamp,/" erigon-config/dynamic-network-conf.json

jq '.firstBatchData' ./agglayer-contracts/deployment/v2/create_rollup_output.json > erigon-config/first-batch-config.json

cp base-dynamic-network-chainspec.json erigon-config/dynamic-network-chainspec.json

# This is a jq script to transform the CDK-style genesis file into an allocs file for erigon
jq_script='
.genesis | map({
  (.address): {
    contractName: (if .contractName == "" then null else .contractName end),
    balance: (if .balance == "" then null else .balance end),
    nonce: (if .nonce == "" then null else .nonce end),
    code: (if .bytecode == "" then null else .bytecode end),
    storage: (if .storage == null or .storage == {} then null else (.storage | to_entries | sort_by(.key) | from_entries) end)
  }
}) | add'

# Use jq to transform the input JSON into the desired format
if ! output_json=$(jq "$jq_script" ./agglayer-contracts/deployment/v2/genesis.json); then
    echo_ts "Error processing JSON with jq"
    exit 1
fi

# Write the output JSON to a file
if ! echo "$output_json" | jq . > "erigon-config/dynamic-network-allocs.json"; then
    echo_ts "Error writing to file erigon-config/dynamic-network-allocs.json"
    exit 1
fi

echo "[rollup] Step 1: Done"

