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
echo " Starting inbound check"
echo "-----------------------"
echo ""

l1PrivateKey=0xbcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31
l1Address=0x8943545177806ED17B9F23F0a21ee5948eCaa776
l2PrivateKey=0xcbb34b64c1a2047fa1ce4cebe25e03985d76f374b96d639c1b894146967943fb
l2Address=0xe859276098f208D003ca6904C6cC26629Ee364Ce
receiverKey=0x37a7601c6c72898629e63d60b3a6c64f7718f75d5c505d81aac57526da1abe3a
receiverAddress=0xe56e585E86C1af0E0E19b97918a2d381c40195Ef
l2Rpc=http://localhost:8123
l1Rpc=$(kurtosis port print cdk el-1-geth-lighthouse rpc)
bridgeRpc=http://localhost:5579
bridgeAddress=0x78908F7A87d589fdB46bdd5EfE7892C5aD6001b6
originNetwork=$(cast call -r $l2Rpc $bridgeAddress "networkID()" | xargs cast to-dec)
echo ">>> Origin Network: $originNetwork"

# make sure the receiver has some money to play with for bridging
cast send -r $l1Rpc --value 0.1ether --private-key $l1PrivateKey $receiverAddress &> /dev/null

# first check the balance on the L2
originalL2Balance=$(cast balance -r $l2Rpc $l2Address)
echo ">>> Original L2 balance: $originalL2Balance"

originalL1Balance=$(cast balance -r $l1Rpc $l1Address)
echo ">>> Original L1 balance: $originalL1Balance"

originalReceiverBalance=$(cast balance -r $l1Rpc $receiverAddress)
echo ">>> Original Receiver balance: $originalReceiverBalance"


# now lets make a bridge transaction from the L1
echo ">>> Making bridge transaction on L2"
polycli ulxly bridge asset --rpc-url "$l2Rpc" \
	--destination-network 0 \
	--legacy=false \
	--value 2000 \
	--bridge-address $bridgeAddress \
	--destination-address $receiverAddress \
	--private-key $l2PrivateKey

# now lets loop until the status of the bridge transaction is ready to claim
echo ">>> Waiting for claim to be ready"

# sleep for a little while to ensure the bridge is good
sleep 10

bridgeData=$(curl -s "$bridgeRpc/bridge/v1/bridges?network_id=$originNetwork&from_address=$l2Address" | jq -r '.bridges[0]')
depositCount=$(echo $bridgeData | jq -r '.deposit_count')

echo ">>> Found deposit count: $depositCount"

echo ">>> Making claim transaction on the L1"

# now we have all the details ready to make the claim - it seems that
# the claim can be automatically processed so this might report that 
# the claim has been made already, but that is absolutely fine.
# occasionally due to gas pricing this call can fail so we will retry
# in a loop a few times until it succeeds with a pause between runs
rm -f inbound-out.txt
counter=0
for i in {1..10}; do
        polycli ulxly claim asset --rpc-url "http://$l1Rpc" \
                --bridge-address $bridgeAddress \
                --legacy=false \
                --bridge-service-url $bridgeRpc \
                --deposit-count $depositCount \
                --destination-address $receiverAddress \
                --deposit-network $originNetwork \
                --wait "60s" \
                --private-key $receiverKey 2>&1 | tee inbound-out.txt

        status=${PIPESTATUS[0]}

        if [ $status -eq 0 ]; then
            echo ">>> Claim successful"
            break
        else
            echo ">>> Claim failed"
            sleep 2
        fi
done


# now we need to get the transaction details to get the cost of the
# bridge transaction.  We need to trim out lots of special characters from the output of polycli, hence the sed commands.
receiptHash=$(cat inbound-out.txt | grep "transaction successful" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*txHash=\([0-9a-fxA-F]*\).*/\1/p')
echo ">>> Receipt hash: $receiptHash"

# wait a little moment for the receipt to be ready
counter=0
receipt=""
while [ -z "$receipt" ]; do
    sleep 2
    receipt=$(cast receipt -r $l1Rpc --json $receiptHash)
    ((counter++))
    if [ $counter -ge 100 ]; then
        echo ">>> Could not get receipt"
        exit 1
    fi
    echo ">>> Waiting for receipt... $counter"
done

receipt=$(cast receipt -r $l1Rpc --json $receiptHash)

echo ">>> Got receipt"

gasUsed=$(echo $receipt | jq -r '.gasUsed' | xargs cast to-dec)
gasPrice=$(echo $receipt | jq -r '.effectiveGasPrice' | xargs cast to-dec)
gasCost=$((gasUsed * gasPrice))
echo ">>> Gas cost (wei): $gasCost"

expectedBalance=$(($originalReceiverBalance + 2000 - $gasCost))
echo ">>> Expected balance: $expectedBalance"

newReceiverBalance=$(cast balance -r $l1Rpc $receiverAddress)
echo ">>> New L1 Balance: $newReceiverBalance"

rm -f inbound-out.txt

if [ "$newReceiverBalance" -eq "$expectedBalance" ]; then
	echo ">>> Success: L1 balance changed as expected."
	exit 0
else
	echo ">>> Failure: L1 balance did not increase as expected."
	exit 1
fi
