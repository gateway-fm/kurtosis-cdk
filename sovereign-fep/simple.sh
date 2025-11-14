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

# make sure previous networks have been removed
./stop.sh

vkeySelector="0x00070001" # hard coded to match the vkey selector from the agg prover program in aggkit/provers repo
proversRepoVKey="0x70d061b24b1d8e5e73705be213bbcd1d20e154a74483849c3decaf0808d471b6"
aggregationVkey="0x00afb45d8064ae10aa6a1793b8f39a24c27268efae2917b5c02950b2377fbf00"
rangeVkeyCommitment="0x416d710344b6b6fa2a0b1a1445f3d6ba4fdd5ab43f0e863b1c522db20f28ad9b"

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

if [ ! -d "lxly-bridge-and-call" ]; then
    git clone --recursive https://github.com/AggLayer/lxly-bridge-and-call
fi

adminZkEVM=$(jq -r '.admin' deploy_output.json)
pol_token=$(jq -r '.polTokenAddress' deploy_output.json)
address_ger=$(jq -r '.polygonZkEVMGlobalExitRootAddress' deploy_output.json)
bridgeAddress=$(jq -r '.polygonZkEVMBridgeAddress' deploy_output.json)
deploymentBlockNumber=$(jq -r '.deploymentRollupManagerBlockNumber' deploy_output.json)
globalExitRootAddress=$(jq -r '.polygonZkEVMGlobalExitRootAddress' deploy_output.json)
rollupManagerAddress=$(jq -r '.polygonRollupManagerAddress' deploy_output.json)
aggLayerGatewayAddress=$(jq -r '.aggLayerGatewayAddress' deploy_output.json)

echo "adminZkEVM: $adminZkEVM"
echo "pol_token: $pol_token"
echo "address_ger: $address_ger"
echo "bridgeAddress: $bridgeAddress"
echo "deploymentBlockNumber: $deploymentBlockNumber"
echo "globalExitRootAddress: $globalExitRootAddress"
echo "rollupManagerAddress: $rollupManagerAddress"

mnemonic="test test test test test test test test test test test junk"
hardhat_key=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # from mnemonic above - used by contracts repo
hardhat_address=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
master_key="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
master_address=0xE34aaF64b29273B7D567FCFc40544c014EEe9970
sequencer_key=0xd828fe23d9d8e92aa1c92ad2b7e172a9c35608d42d114068abd7bb2da98c38cd
sequencer_address=0x0318A80977AcEF01302CA8911164d597cE5804a4

# fund the sequencer and hardhat address used for deploying things
cast send --rpc-url "$l1_rpc_url" --private-key "$master_key" --value "1ether" --quiet "$sequencer_address"
cast send --rpc-url "$l1_rpc_url" --private-key "$master_key" --value "1ether" --quiet "$hardhat_address"

# now discover the chain ID that we'll use for this deployment
rollupCount=$(cast call -r "$l1_rpc_url" "$rollupManagerAddress" "rollupCount()(uint32)")
echo "Rollup count: $rollupCount"

# now we can use the rollup count to determine the chain ID for this deployment
l2ChainId=$((rollupCount + 1000))
echo "Using chain ID: $l2ChainId"

nextRollupId=$((rollupCount + 1))

now=$(date +%s)

# clone the rollup creation parameters from the originally deployed network and we can change the values
# we care about and put it back before launcing the new rollup.
cp zkevm-contracts/deployment/v2/create_rollup_parameters.json.example ./create_rollup_parameters.json
jq '.trustedSequencerURL = "http://127.0.0.1:8124"' create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
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
jq ".aggchainParams.initParams.l2BlockTime = 4" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.submissionInterval = 4" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.optimisticModeManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.aggregationVkey = \"$aggregationVkey\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.rangeVkeyCommitment = \"$rangeVkeyCommitment\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.startingBlockNumber = 10" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initParams.startingTimestamp = $now" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.vKeyManager = \"$adminZkEVM\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.useDefaultSigners = false" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.useDefaultVkeys = false" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initAggchainVKeySelector = \"$vkeySelector\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.aggchainVKeySelector = \"$vkeySelector\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.initOwnedAggchainVKey = \"$proversRepoVKey\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.ownedAggchainVKey = \"$proversRepoVKey\"" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
jq ".aggchainParams.signers = [[\"$sequencer_address\", \" \"]]" create_rollup_parameters.json > temp.json; mv temp.json create_rollup_parameters.json
cp create_rollup_parameters.json zkevm-contracts/deployment/v2/create_rollup_parameters.json

# clear out any previous genesis file creations
pushd zkevm-contracts/tools/createSovereignGenesis
rm -rf genesis-rollupID*
rm -rf output-rollupID*
popd

cp ./zkevm-contracts/tools/createSovereignGenesis/create-genesis-sovereign-params.json.example create.json

# change the values we need to and build our gensis file up
jq ".rollupManagerAddress = \"$rollupManagerAddress\"" create.json > temp.json; mv temp.json create.json
jq ".chainID = \"$l2ChainId\"" create.json > temp.json; mv temp.json create.json
jq ".rollupID = \"2\"" create.json > temp.json; mv temp.json create.json
jq ".bridgeManager = \"$bridgeAddress\"" create.json > temp.json; mv temp.json create.json
jq ".globalExitRootUpdater = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq ".globalExitRootRemover = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq ".emergencyBridgePauser = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq ".emergencyBridgeUnpauser = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq ".proxiedTokensManager = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq ".preMintAccounts = [{\"balance\": \"1000000000000000000\", \"address\": \"$master_address\"}, {\"balance\": \"1000000000000000000\", \"address\": \"0xe859276098f208D003ca6904C6cC26629Ee364Ce\"}, {\"balance\": \"1000000000000000000\", \"address\": \"0x0318A80977AcEF01302CA8911164d597cE5804a4\"}]" create.json > temp.json; mv temp.json create.json
jq ".timelockParameters.adminAddress = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq ".useAggOracleCommittee = false" create.json > temp.json; mv temp.json create.json
jq ".aggOracleOwner = \"$master_address\"" create.json > temp.json; mv temp.json create.json
jq "del(.formatGenesis)" create.json > temp.json; mv temp.json create.json

cp create.json ./zkevm-contracts/tools/createSovereignGenesis/create-genesis-sovereign-params.json

cd zkevm-contracts

# make sure the l1 endpoint is pointing to kurtosis from hardhat
sed -i '' "s#url: '.*',#url: 'http://${l1_rpc_url}',#g" hardhat.config.ts

echo "[contracts]: Creating rollup"
export DEPLOYER_PRIVATE_KEY=0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625

# here we need to stop the default vkey selector from being sent to the contract, this step should only happen for the first rollup
# kurtosis scripts do the same here to stop this small step from happening.
sed -i '' '/await aggLayerGateway\.addDefaultAggchainVKey(/,/);/s/^/\/\/ /' deployment/v2/4_createRollup.ts

# remove any old create rollup output files
rm -f zkevm-contracts/deployment/v2/create_rollup_output_*.json 2> /dev/null
rm -f zkevm-contracts/tools/createSovereignGenesis/genesis-rollupID*.json 2> /dev/null
rm -f zkevm-contracts/tools/createSovereignGenesis/output-rollupID*.json 2> /dev/null

npx hardhat run deployment/v2/4_createRollup.ts --network localhost 2>&1 | tee 05_create_rollup.out
# move the create rollup output file into something more predictable
echo "[contracts]: Done\n"

echo "[contracts]: Creating genesis"
# quickly get how many rollups there are so we can use this in the genesis input file
npx hardhat run ./tools/createSovereignGenesis/create-sovereign-genesis.ts --network localhost 2>&1 | tee 04_create_genesis.out
echo "[contracts]: Done\n"

# copy the created rollup and genesis file from the zkevm folder to where we can work with them easily
cd $pwd
mv $(ls zkevm-contracts/deployment/v2/create_rollup_output_*.json) create_rollup_output.json
mv $(ls zkevm-contracts/tools/createSovereignGenesis/genesis-rollupID*.json) genesis.json

echo "[contracts]: Minting POL tokens for sequencer and adding approval for rollup"
# Mint POL tokens for sequencer
cast send \
    --private-key "$sequencer_key" \
    --rpc-url "$l1_rpc_url" \
    --quiet \
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
    --quiet \
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
sed -i '' "s/zkevm.address-rollup: .*/zkevm.address-rollup: $rollupManagerAddress/" erigon-config/dynamic-network-config.yaml
sed -i '' "s/zkevm.address-ger-manager: .*/zkevm.address-ger-manager: $address_ger/" erigon-config/dynamic-network-config.yaml

# conf file
cp base-dynamic-network-conf.json erigon-config/dynamic-network-conf.json
root=$(jq -r '.genesis' create_rollup_output.json)
sed -i '' "s/\"root\": .*/\"root\": \"$root\",/" erigon-config/dynamic-network-conf.json

cp base-dynamic-network-chainspec.json erigon-config/dynamic-network-chainspec.json
sed -i '' "s/chainId\": .*/chainId\": $l2ChainId,/" erigon-config/dynamic-network-chainspec.json

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
if ! output_json=$(jq "$jq_script" genesis.json); then
    echo "Error processing JSON with jq"
    exit 1
fi

# Write the output JSON to a file
if ! echo "$output_json" | jq . > "erigon-config/dynamic-network-allocs.json"; then
    echo "Error writing to file erigon-config/dynamic-network-allocs.json"
    exit 1
fi

# now create the folders for the sequencer and rpc erigon configs so we can stand both up
mkdir -p erigon-sequencer-config
mkdir -p erigon-rpc-config

cp erigon-config/dynamic-network-config.yaml erigon-sequencer-config/dynamic-network-config.yaml
cp erigon-config/dynamic-network-conf.json erigon-sequencer-config/dynamic-network-conf.json
cp erigon-config/dynamic-network-chainspec.json erigon-sequencer-config/dynamic-network-chainspec.json
cp erigon-config/dynamic-network-allocs.json erigon-sequencer-config/dynamic-network-allocs.json

cp erigon-config/dynamic-network-config.yaml erigon-rpc-config/dynamic-network-config.yaml
cp erigon-config/dynamic-network-conf.json erigon-rpc-config/dynamic-network-conf.json
cp erigon-config/dynamic-network-chainspec.json erigon-rpc-config/dynamic-network-chainspec.json
cp erigon-config/dynamic-network-allocs.json erigon-rpc-config/dynamic-network-allocs.json

# now make sure the sequencer runs on different ports and doesn't clash with the rpc
sed -i '' "s/http.port: 8123/http.port: 8124/g" erigon-sequencer-config/dynamic-network-config.yaml
sed -i '' "s/zkevm.data-stream-port: 6910/zkevm.data-stream-port: 6911/g" erigon-sequencer-config/dynamic-network-config.yaml
sed -i '' "s/private.api.addr: localhost:9090/private.api.addr: localhost:9091/g" erigon-sequencer-config/dynamic-network-config.yaml
sed -i '' "s/authrpc.port: 8551/authrpc.port: 8552/g" erigon-sequencer-config/dynamic-network-config.yaml
sed -i '' "s/torrent.port: 42072/torrent.port: 42073/g" erigon-sequencer-config/dynamic-network-config.yaml

echo "[rollup] Step 1: Done\n"

# now start erigon up
docker compose -f cdk-erigon.yaml up erigon-sequencer -d
sleep 5
docker compose -f cdk-erigon.yaml up erigon-rpc -d

sleep 5

# wait until we have 10 blocks on the L2 before starting the agg oracle - FEP is enabled at block 10 on the L2
for i in {1..1000}; do
    number=$(cast block -r "http://127.0.0.1:8123" --json | jq '.number' | xargs cast to-dec)
    if [ "$number" -gt 10 ]; then
        break
    fi
    echo "Waiting for 10 blocks on the L2... $number"
    sleep 2
done
echo "10 blocks on the L2 found, continuing..."

echo "Launching deterministic deployment proxy"
signer_address="0x3fab184622dc19b6109349b94811493bf2a45362"
gas_cost="0.01ether"
transaction="0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222"
deployer_address="0x4e59b44847b379578588920ca78fbf26c0b4956c"
eth_address="$(cast wallet address --private-key "$master_key")"
account_nonce="$(cast nonce --rpc-url "http://127.0.0.1:8123" "$eth_address")"
cast send \
    --rpc-url "http://127.0.0.1:8123" \
    --private-key "$master_key" \
    --value "$gas_cost" \
    --nonce "$account_nonce" \
    --quiet \
    "$signer_address"
cast publish --rpc-url "http://127.0.0.1:8123" "$transaction"
if [[ $(cast code --rpc-url "http://127.0.0.1:8123" $deployer_address) == "0x" ]]; then
    echo_ts "No code at expected l2 address: $deployer_address"
    exit 1;
fi
echo "Deterministic deployment proxy launched"

export ADDRESS_PROXY_ADMIN=0x242daE44F5d8fb54B198D03a94dA45B5a4413e21
export ADDRESS_LXLY_BRIDGE=0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe
export DEPLOYER_PRIVATE_KEY="$master_key"

echo "Running bridge deploy and call on L1"
cd lxly-bridge-and-call
forge script script/DeployInitBridgeAndCall.s.sol --rpc-url "$l1_rpc_url" --legacy --broadcast
cd $pwd
echo "Done bridge deploy and call on L1"

echo "Running bridge deploy and call on L2"
cd lxly-bridge-and-call
forge script script/DeployInitBridgeAndCall.s.sol --rpc-url "http://127.0.0.1:8123" --legacy --broadcast
cd $pwd
echo "Done bridge deploy and call on L2"

echo "Adding signer to the AggchainFEP contract"
cast send -r $l1_rpc_url --quiet --private-key $master_key $address_zkevm "updateSignersAndThreshold((address,uint256)[],(address,string)[],uint256)" "[]" "[($sequencer_address,' ')]" "1"
echo "Done adding signer to the AggchainFEP contract"

# now we need to determine if the vkey selector pair is on the L1 or not and add it if we don't have it there yet
echo "Checking AggLayer gateway for default Aggchain VKey"
if cast call -r $l1_rpc_url $aggLayerGatewayAddress "getDefaultAggchainVKey(bytes4)" "$vkeySelector" >/dev/null 2>&1; then
    echo "Default Aggchain VKey already set for selector $vkeySelector"
else
    echo "Default Aggchain VKey missing for selector $vkeySelector; adding it now"
    cast send -r $l1_rpc_url --quiet --private-key $master_key $aggLayerGatewayAddress "addDefaultAggchainVKey(bytes4,bytes32)" "$vkeySelector" "$proversRepoVKey"
fi


# now start aggkit up
aggLayerGrpcUrl=$(kurtosis port print cdk agglayer aglr-grpc)
agglayerGrpcAsHttpUrl=$(echo $aggLayerGrpcUrl | sed 's#grpc#http#')
aggLayerReadRpcUrl=$(kurtosis port print cdk agglayer aglr-readrpc)
aggLayerProverGrpcUrl=$(echo "$(kurtosis port print cdk aggkit-prover-001 grpc)" | sed 's#grpc://##')
aggLayerProverGrpcUrl="http://127.0.0.1:4446" # running on localhost - not using the kurtosis version
rollupAddress=$(jq -r '.rollupAddress' create_rollup_output.json)
l2GerContractAddress=$(jq -r '.genesis[] | select(.contractName == "GlobalExitRootManagerL2SovereignChain proxy") | .address' genesis.json)
claimSenderAddress="0x635243A11B41072264Df6c9186e3f473402F94e9"
proposerUrl=$(kurtosis port print cdk op-succinct-proposer-001 grpc)
proposerUrlAsHttp=$(echo $proposerUrl | sed 's#grpc#http#')

cp templates/aggkit-cdk-config.toml aggkit-config.toml
sed -i '' "s#{{network_id}}#$nextRollupId#g" aggkit-config.toml
sed -i '' "s#{{l1_rpc_url}}#$l1_rpc_url#g" aggkit-config.toml
sed -i '' "s#{{agglayer_grpc_url}}#$aggLayerGrpcUrl#g" aggkit-config.toml
sed -i '' "s#{{agglayer_grpc_as_http_url}}#$agglayerGrpcAsHttpUrl#g" aggkit-config.toml
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

cp templates/aggkit-prover-config.toml aggkit-prover-config.toml
sed -i '' "s#{{aggkit_prover_grpc_port}}#4446#g" aggkit-prover-config.toml
sed -i '' "s#{{log_level}}#info#g" aggkit-prover-config.toml
sed -i '' "s#{{metrics_port}}#9093#g" aggkit-prover-config.toml
sed -i '' "s#{{network_id}}#$nextRollupId#g" aggkit-prover-config.toml
sed -i '' "s#{{primary_prover}}#mock-prover#g" aggkit-prover-config.toml
sed -i '' "s#{{l1_rpc_url}}#http://$l1_rpc_url#g" aggkit-prover-config.toml
sed -i '' "s#{{l2_el_rpc_url}}#http://127.0.0.1:8123#g" aggkit-prover-config.toml
sed -i '' "s#{{l2_cl_rpc_url}}#http://127.0.0.1:8123#g" aggkit-prover-config.toml
sed -i '' "s#{{rollup_manager_address}}#$rollupManagerAddress#g" aggkit-prover-config.toml
sed -i '' "s#{{global_exit_root_address}}#$l2GerContractAddress#g" aggkit-prover-config.toml
sed -i '' "s#{{op_succinct_mock}}#true#g" aggkit-prover-config.toml
sed -i '' "s#{{proposer_url}}#$proposerUrlAsHttp#g" aggkit-prover-config.toml
sed -i '' "s#{{agglayer_prover_network_url}}#https://rpc.production.succinct.xyz#g" aggkit-prover-config.toml
sed -i '' "s#{{location}}#$pwd#g" aggkit-prover-config.toml

cp templates/evm-sketch-genesis.json evm-sketch-genesis.json
sed -i '' "s#{{zkevm_rollup_chain_id}}#$l2ChainId#g" evm-sketch-genesis.json

mkdir -p aggkit-oracle
mkdir -p aggkit-bridge
mkdir -p aggkit-sender
mkdir -p aggkit-prover

cast wallet import --keystore-dir aggkit-oracle --private-key $master_key --unsafe-password "pSnv6Dh5s9ahuzGzH9RoCDrKAMddaX3m" aggoracle.keystore
cast wallet import --keystore-dir aggkit-bridge --private-key $master_key --unsafe-password "pSnv6Dh5s9ahuzGzH9RoCDrKAMddaX3m" bridge.keystore
cast wallet import --keystore-dir aggkit-bridge --private-key $master_key --unsafe-password "pSnv6Dh5s9ahuzGzH9RoCDrKAMddaX3m" claimsponsor.keystore
cast wallet import --keystore-dir aggkit-sender --private-key $sequencer_key --unsafe-password "pSnv6Dh5s9ahuzGzH9RoCDrKAMddaX3m" sequencer.keystore


cp aggkit-config.toml aggkit-oracle/config.toml
docker compose -f aggkit.yaml up agg-oracle -d

cp aggkit-config.toml aggkit-bridge/config.toml
sed -i '' "s/Port = \"5576\"/Port = \"5578\"/g" aggkit-bridge/config.toml
sed -i '' "s/Port = \"5577\"/Port = \"5579\"/g" aggkit-bridge/config.toml
docker compose -f aggkit.yaml up agg-bridge -d

cp aggkit-prover-config.toml aggkit-prover/config.toml
sed -i '' "s/Port = \"5576\"/Port = \"5580\"/g" aggkit-prover/config.toml
sed -i '' "s/Port = \"5577\"/Port = \"5581\"/g" aggkit-prover/config.toml
cp evm-sketch-genesis.json aggkit-prover/evm-sketch-genesis.json
# docker compose -f aggkit.yaml up agg-prover -d

cp aggkit-config.toml aggkit-sender/config.toml
mkdir -p aggkit-sender/tmp
sed -i '' "s/Port = \"5576\"/Port = \"5582\"/g" aggkit-sender/config.toml
sed -i '' "s/Port = \"5577\"/Port = \"5583\"/g" aggkit-sender/config.toml
# for debugging on your own machine you can uncomment the following config changes and stop the container running
# sed -i '' "s#/etc/aggkit/sequencer.keystore#${pwd}/aggkit-sender/sequencer.keystore#g" aggkit-sender/config.toml
# sed -i '' "s#/tmp#${pwd}/aggkit-sender/tmp#g" aggkit-sender/config.toml
docker compose -f aggkit.yaml up agg-sender -d
