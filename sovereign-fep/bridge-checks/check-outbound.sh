#!/bin/bash

# A simple script to make a bridge transaction and claim it on the L2 and check the balance changed
# as expected.  The script can only be run in an environment where other parties aren't interacting
# with the bridge because it relies on the assumption that the most recent bridge action from the
# hard coded addresses is the one from this script

# You will need kurtosis installed and running a cdk environment for this script to work.  You
# also need the following installed:
# - polycli
# - jq
# - curl

echo ""
echo "-----------------------"
echo " Starting outbound check"
echo "-----------------------"
echo ""

l1PrivateKey=0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31
l1Address=0x8943545177806ED17B9F23F0a21ee5948eCaa776
l2PrivateKey=0xcbb34b64c1a2047fa1ce4cebe25e03985d76f374b96d639c1b894146967943fb # not related to receiver - must be funded
l2Address=0xdD1a36FdaA474386A9Fd789f7a07937f59F43A9b
l2Rpc=http://localhost:8123
l1Rpc=$(kurtosis port print cdk el-1-geth-lighthouse rpc)
bridgeRpc=http://localhost:5579
bridgeAddress=0x78908F7A87d589fdB46bdd5EfE7892C5aD6001b6
transferAmount=100000000
destinationNetwork=$(cast call -r $l2Rpc $bridgeAddress "networkID()")
echo ">>> Destination Network: $destinationNetwork"

# first check the balance on the L2
originalL2Balance=$(cast balance -r $l2Rpc $l2Address)
echo ">>> Original L2 balance: $originalL2Balance"

originalL1Balance=$(cast balance -r $l1Rpc $l1Address)
echo ">>> Original L1 balance: $originalL1Balance"

expectedBalance=$(($originalL2Balance + $transferAmount))

# now lets make a bridge transaction from the L1
echo ">>> Making bridge transaction on L1"
polycli ulxly bridge asset --rpc-url "http://$l1Rpc" \
	--destination-network $destinationNetwork \
	--value $transferAmount \
	--bridge-address $bridgeAddress \
	--destination-address $l2Address \
	--private-key $l1PrivateKey

# now lets loop until the status of the bridge transaction is ready to claim
echo ">>> Waiting for claim to be ready"

# sleep for a little while to ensure the bridge is good
sleep 10

bridgeData=$(curl -s "$bridgeRpc/bridge/v1/bridges?network_id=0" | jq -r '.bridges[0]')

depositCount=$(echo $bridgeData | jq -r '.deposit_count')
echo ">>> Found deposit count: $depositCount"

echo ">>> Making claim transaction on the L2"

# now we have all the details ready to make the claim - it seems that
# the claim can be automatically processed so this might report that 
# the claim has been made already, but that is absolutely fine.
# occasionally due to gas pricing this call can fail so we will retry
# in a loop a few times until it succeeds with a pause between runs
counter=0
until polycli ulxly claim asset --rpc-url "$l2Rpc" \
	--bridge-address $bridgeAddress \
	--legacy=false \
	--bridge-service-url $bridgeRpc \
	--deposit-count $depositCount \
	--destination-address $l2Address \
	--deposit-network 0 \
	--private-key $l2PrivateKey; do
	((counter++))
	echo ">>> Can't make the claim at the moment..."
	if [[ $counter -ge 10 ]]; then
		echo ">>> Cannot make the claim, exiting"
		exit 1
	fi

	# lets check if the balance has increased as the claim could have been
	# automatically made and the claim tx will fail because of this
	newL2Balance=$(cast balance -r $l2Rpc $l2Address)
	if [ "$newL2Balance" -eq "$expectedBalance" ]; then
		echo ">>> Success: L2 balance increased as expected."
		exit 0
	fi

	sleep 2
done

# lets check if the balance has increased as the claim could have been
# automatically made and the claim tx will fail because of this
newL2Balance=$(cast balance -r $l2Rpc $l2Address)

if [ "$newL2Balance" -eq "$expectedBalance" ]; then
	echo ">>> Success: L2 balance increased as expected."
	exit 0
else
	echo ">>> Failure: L2 balance did not increase as expected."
	exit 1
fi