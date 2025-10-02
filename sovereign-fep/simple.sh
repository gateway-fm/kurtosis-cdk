#!/bin/bash
#
# to use this script you will need the following installed:
# node, npm, docker, docker-compose, cast, jq, sed, git
#
# to use this script ensure that you are running a kurtosis environment already that has the L1 running
# along with agg layer and the other components supporting that.  We are going to attach to that environment
# to run up the cdk-erigon components and start communicating with the AggLayer that way.
#
# `kurtosis run --enclave=cdk --args-file=./.github/tests/op-succinct/mock-prover.yml .`
#
#
pwd=$(pwd)

l2ChainId=1009
vkeySelector="0x${l2ChainId}0001" 
echo "Using chain Id $l2ChainId and vkey selector $vkeySelector"

l1_rpc_url=$(kurtosis port print cdk el-1-geth-lighthouse rpc)
contracts_container=$(docker ps -a --filter "name=contracts-001" --format "{{.ID}}")
docker cp $contracts_container:/opt/zkevm/deploy_output.json .
docker cp $contracts_container:/opt/contract-deploy/create_new_rollup.json .

# now cheekily pull all of the contracts data directly from the kurtosis container so we can inherit this exactly
# as it was used to launch the rollup inside of kurtosis.  We've had little clashes between things when trying to
# just clone it ourselves and use it so taking it from the container seems the safest and easiest path right now.
if [ ! -d "zkevm-contracts" ]; then
    docker cp $contracts_container:/opt/zkevm-contracts .
    cd zkevm-contracts
    npm i 
    npx hardhat compile
    cd $pwd
fi

mnemonic="test test test test test test test test test test test junk"
hardhat_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # from mnemonic above - used by contracts repo
hardhat_address=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
master_key="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
sequencer_key=0xd828fe23d9d8e92aa1c92ad2b7e172a9c35608d42d114068abd7bb2da98c38cd
sequencer_address=0x0318A80977AcEF01302CA8911164d597cE5804a4

# fund the sequencer and hardhat address used for deploying things
cast send --rpc-url "$l1_rpc_url" --private-key "$master_key" --value "1ether" "$sequencer_address"
cast send --rpc-url "$l1_rpc_url" --private-key "$master_key" --value "1ether" "$hardhat_address"


# clone the rollup creation parameters from the originally deployed network and we can change the values
# we care about and put it back before launcing the new rollup.
adminZkEVM=$(jq -r '.admin' deploy_output.json)
cp zkevm-contracts/deployment/v2/create_rollup_parameters.json.example ./create_rollup_parameters.json
jq '.trustedSequencerURL = "http://localhost:8124"' create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq '.networkName = "sovereign-fep"' create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq '.description = "cdk-erigon sovereign fep"' create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".trustedSequencer = \"$sequencer_address\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".chainID = $l2ChainId" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".adminZkEVM = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq '.gasTokenAddress = ""' create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".deployerPvtKey = \"$master_key\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".sovereignParams.bridgeManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".sovereignParams.globalExitRootUpdater = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".sovereignParams.globalExitRootRemover = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".sovereignParams.emergencyBridgePauser = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".sovereignParams.emergencyBridgeUnpauser = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".sovereignParams.proxiedTokensManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.aggchainManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.optimisticModeManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.vKeyManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.useDefaultSigners = true" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.useDefaultVkeys = false" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initAggchainVKeySelector = \"$vkeySelector\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.signers = []" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
cp create_rollup_parameters.json zkevm-contracts/deployment/v2/create_rollup_parameters.json

cd zkevm-contracts

# make sure the l1 endpoint is pointing to kurtosis from hardhat
sed -i '' "s#http://el-1-geth-lighthouse:.*#http://$l1_rpc_url\',#" hardhat.config.ts
sed -i '' "s#http://127.0.0.1:.*#http://$l1_rpc_url\',#" hardhat.config.ts

echo "[contracts]: Creating genesis"
MNEMONIC="$mnemonic" npx ts-node deployment/v2/1_createGenesis.ts 2>&1 | tee 04_create_genesis.out
cp zkevm-contracts/deployment/v2/genesis.json genesis.json
echo "[contracts]: Done\n"

echo "[contracts]: Creating rollup"
DEPLOYER_PRIVATE_KEY=0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625 npx hardhat run deployment/v2/4_createRollup.ts --network localhost 2>&1 | tee 05_create_rollup.out
# move the create rollup output file into something more predictable
cd $pwd
mv $(ls zkevm-contracts/deployment/v2/create_rollup_output_*.json) create_rollup_output.json
echo "[contracts]: Done\n"

echo "[contracts]: Minting POL tokens for sequencer and adding approval for rollup"
# Mint POL tokens for sequencer
pol_token=$(jq -r '.polTokenAddress' deploy_output.json)
cast send \
    --private-key "$sequencer_key" \
    --rpc-url "$l1_rpc_url" \
    "$pol_token" \
    'mint(address,uint256)' \
    "$sequencer_address" \
    "1000000000000000000000000000"
echo "[contracts]: Done\n"

address_zkevm=$(jq -r '.rollupAddress' create_rollup_output.json)
cast send \
    --private-key "$sequencer_key" \
    --legacy \
    --rpc-url "$l1_rpc_url" \
    "$pol_token" \
    'approve(address,uint256)(bool)' \
    "$address_zkevm" 1000000000000000000000000000
echo "[contracts] Step 7: Done\n"

# now we can begin to launch the rollup itself
echo "[rollup] Step 1: Creating configs"
# erigon config
mkdir -p erigon-config
cp base-dynamic-network-config.yaml erigon-config/dynamic-network-config.yaml

sed -i '' "s#zkevm.l1-rpc-url: .*#zkevm.l1-rpc-url: http://$l1_rpc_url#" erigon-config/dynamic-network-config.yaml
sed -i '' "s/zkevm.l2-chain-id: .*/zkevm.l2-chain-id: $l2ChainId/" erigon-config/dynamic-network-config.yaml
sed -i '' "s/zkevm.address-sequencer: .*/zkevm.address-sequencer: $sequencer_address/" erigon-config/dynamic-network-config.yaml

address_zkevm=$(jq -r '.rollupAddress' create_rollup_output.json)
sed -i '' "s/zkevm.address-zkevm: .*/zkevm.address-zkevm: $address_zkevm/" erigon-config/dynamic-network-config.yaml

address_rollup=$(jq -r '.polygonRollupManagerAddress' deploy_output.json)
sed -i '' "s/zkevm.address-rollup: .*/zkevm.address-rollup: $address_rollup/" erigon-config/dynamic-network-config.yaml

address_ger=$(jq -r '.polygonZkEVMGlobalExitRootAddress' deploy_output.json)
sed -i '' "s/zkevm.address-ger-manager: .*/zkevm.address-ger-manager: $address_ger/" erigon-config/dynamic-network-config.yaml

# conf file
cp base-dynamic-network-conf.json erigon-config/dynamic-network-conf.json
root=$(jq -r '.genesis' create_rollup_output.json)
sed -i '' "s/\"root\": .*/\"root\": \"$root\",/" erigon-config/dynamic-network-conf.json

cp base-dynamic-network-chainspec.json erigon-config/dynamic-network-chainspec.json
sed -i '' "s/chainId: .*/chainId: $l2ChainId,/" erigon-config/dynamic-network-chainspec.json

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
if ! output_json=$(jq "$jq_script" ./zkevm-contracts/deployment/v2/genesis.json); then
    echo_ts "Error processing JSON with jq"
    exit 1
fi

# Write the output JSON to a file
if ! echo "$output_json" | jq . > "erigon-config/dynamic-network-allocs.json"; then
    echo_ts "Error writing to file erigon-config/dynamic-network-allocs.json"
    exit 1
fi

echo "[rollup] Step 1: Done\n"

# create the data directory for cdk-erigon to use
mkdir -p data

# now start erigon up
docker compose -f cdk-erigon.yaml up -d

# now start aggkit up
aggLayerGrpcUrl=$(kurtosis port print cdk agglayer aglr-grpc)
aggLayerReadRpcUrl=$(kurtosis port print cdk agglayer aglr-readrpc)
aggLayerProverGrpcUrl=$(echo "$(kurtosis port print cdk agglayer-prover api)" | sed 's#grpc://##')
bridgeAddress=$(jq -r '.polygonZkEVMBridgeAddress' deploy_output.json)
deploymentBlockNumber=$(jq -r '.deploymentRollupManagerBlockNumber' deploy_output.json)
globalExitRootAddress=$(jq -r '.polygonZkEVMGlobalExitRootAddress' deploy_output.json)
rollupManagerAddress=$(jq -r '.polygonRollupManagerAddress' deploy_output.json)
rollupAddress=$(jq -r '.rollupAddress' create_rollup_output.json)
l2GerContractAddress=$(jq -r '.genesis[] | select(.contractName == "PolygonZkEVMGlobalExitRootL2 proxy") | .address' genesis.json)
claimSenderAddress="0x635243A11B41072264Df6c9186e3f473402F94e9"

cp templates/aggkit-cdk-config.toml aggkit-config.toml

sed -i '' "s#{{l1_rpc_url}}#$l1_rpc_url#g" aggkit-config.toml
sed -i '' "s#{{agglayer_grpc_url}}#$aggLayerGrpcUrl#g" aggkit-config.toml
sed -i '' "s#{{agglayer_readrpc_url}}#$aggLayerReadRpcUrl#g" aggkit-config.toml
sed -i '' "s#{{agglayer_prover_grpc}}#$aggLayerProverGrpcUrl#g" aggkit-config.toml
sed -i '' "s#{{zkevm_bridge_address}}#$bridgeAddress#g" aggkit-config.toml
sed -i '' "s#{{zkevm_rollup_manager_block_number}}#$deploymentBlockNumber#g" aggkit-config.toml
sed -i '' "s#{{zkevm_global_exit_root_address}}#$globalExitRootAddress#g" aggkit-config.toml
sed -i '' "s#{{zkevm_rollup_manager_address}}#$rollupManagerAddress#g" aggkit-config.toml
sed -i '' "s#{{pol_token_address}}#$pol_token#g" aggkit-config.toml
sed -i '' "s#{{zkevm_rollup_address}}#$rollupAddress#g" aggkit-config.toml
sed -i '' "s#{{zkevm_global_exit_root_l2_address}}#$l2GerContractAddress#g" aggkit-config.toml
sed -i '' "s#{{zkevm_l2_claimsponsor_address}}#$claimSenderAddress#g" aggkit-config.toml
sed -i '' "s#{{l2_chain_id}}#$l2ChainId#g" aggkit-config.toml

mkdir -p aggkit-oracle
cp aggkit-config.toml aggkit-oracle/config.toml
cast wallet import --keystore-dir aggkit-oracle --private-key $master_key --unsafe-password "pSnv6Dh5s9ahuzGzH9RoCDrKAMddaX3m" aggoracle.keystore