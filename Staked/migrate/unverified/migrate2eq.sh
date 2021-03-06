#!/bin/bash

# This script makes the neccesary transactions to migrate
# coin between 2 assetchains on the same -ac_cc id
waitforconfirm () {
  confirmations=0
  while [[ ${confirmations} -lt 1 ]]; do
    sleep 1
    confirmations=$($2 gettransaction $1 | jq -r .confirmations)
    # Keep re-broadcasting
    $2 sendrawtransaction $($2 getrawtransaction $1) > /dev/null 2>&1
  done
}

printbalance () {
  src_balance=`$cli_source getbalance`
  tgt_balance=`$cli_target getbalance`
  echo "[$source] : $src_balance"
  echo "[$target] : $tgt_balance"
}

# use https://github.com/smk762/kmd_pulp/blob/master/Staked/staked-cli and link to /usr/local/bin
staked-cli getbalance

num_migrates=0
ac_json=$(curl https://raw.githubusercontent.com/StakedChain/StakedNotary/master/assetchains.json 2>/dev/null)
for row in $(echo "${ac_json}" | jq  -r '.[].ac_name'); do
	source=$(echo $row)
	for row in $(echo "${ac_json}" | jq  -r '.[].ac_name'); do
		target=$(echo $row)
		if [[ $target != $source ]]; then
			# Alias for running cli
			cli_target="komodo-cli -ac_name=$target"
			cli_source="komodo-cli -ac_name=$source"
			amount=5

			addresses=$($(echo komodo-cli -ac_name=$target listaddressgroupings))
                        num_addr=$(echo $addresses | jq '.[] | length')
			echo "$num_addr addresses at target $target"

			for row in $(echo "${addresses}" | jq -c -r '.[][]'); do
	        		_jq() {
	                		echo ${row} | jq -r ${1}
			        }
		        	address=$(_jq '.[0]')
				src_balance=`$cli_source getbalance`
				tgt_balance=`$cli_target getbalance`
			        if [ $( printf "%.0f" $src_balance) -gt $( printf "%.0f" $tgt_balance) ]; then
			        	echo "Source $source balance: $src_balance"
			        	echo "Target $target balance: $tgt_balance"
					diff=$(printf "%.0f" $(echo $src_balance-$tgt_balance|bc))
                                        if  [ $diff -lt 25 ]; then
                                                echo "**** Skipping Migration  ************************************"
                                                echo "**** $source chain balance is within 25 coins of $target chain at $(date) ****"
                                                break
                                        fi
					spread=$(printf "%.0f" $(echo 2*$num_addr|bc))
					if [ $spread -gt 5 ]; then
 						spread=5
					fi
					amount=$(printf "%.0f" $(echo $diff/$spread|bc))
                                        if [ $amount -lt 2 ]; then
                                                echo "**** Skipping Migration - amount less than 2 ************************************"
						break
                                        fi

					num_migrates=$(echo $num_migrates+1|bc)
					echo "**** Starting Migration #${num_migrates} ************************************"
			        	echo "**** Sending $amount from $source to $target address $address at $(date) ****"

				        echo "Raw tx that we will work with"
				        txraw=`$cli_source createrawtransaction "[]" "{\"$address\":$amount}"`
			        	echo "$txraw txraw"
				        echo "Convert to an export tx"
		        		exportData=`$cli_source migrate_converttoexport $txraw $target $amount`
				        echo "$exportData exportData"
			        	exportRaw=`echo $exportData | jq -r .exportTx`
				        echo "$exportRaw exportRaw"
		        		echo "Fund it"
				        exportFundedData=`$cli_source fundrawtransaction $exportRaw`
			        	echo "$exportFundedData exportFundedData"
				        exportFundedTx=`echo $exportFundedData | jq -r .hex`
		        		echo "$exportFundedTx exportFundedTx"
			        	payouts=`echo $exportData | jq -r .payouts`
			        	echo "$payouts payouts"

				        echo "4. Sign rawtx and export at $(date)"
			        	signedhex=`$cli_source signrawtransaction $exportFundedTx | jq -r .hex`
				        echo "$signedhex signedhex"
		        		sentTX=`$cli_source sendrawtransaction $signedhex`
				        echo "$sentTX sentTX"

				        echo "5. Wait for a confirmation on source ($source) chain. at $(date)"
			        	waitforconfirm "$sentTX" "$cli_source"
				        echo "[$source] : Confirmed export $sentTX"

			        	echo " 6. Use migrate_createimporttransaction to create the import TX at $(date)"
			        	created=0
				        while [[ ${created} -eq 0 ]]; do
			        	  importTX=`$cli_source migrate_createimporttransaction $signedhex $payouts`
				          echo "$importTX importTX"
		        		  if [[ ${importTX} != "" ]]; then
				            created=1
			        	  fi
				          sleep 60
		        		done
				        echo "importTX"
			        	echo "Create import transaction to $target sucessful at $(date)!"

				        # 8. Use migrate_completeimporttransaction on KMD to complete the import tx
			        	created=0
				        while [[ $created -eq 0 ]]; do
		        		  completeTX=`komodo-cli migrate_completeimporttransaction $importTX`
				          echo "$completeTX completeTX"
			        	  if [[ $completeTX != "" ]]; then
				            created=1
		        		  fi
			        	  sleep 60
			        	done
				        echo "Sign import transaction on KMD complete at $(date)!"

				        # 9. Broadcast tx to target chain
		        		sent=0
			        	while [[ $sent -eq 0 ]]; do
			        	  sent_iTX=`$cli_target sendrawtransaction $completeTX`
				          if [[ $sent_iTX != "" ]]; then
			        	    sent=1
				          fi
		        		  sleep 60
				        done
			        	waitforconfirm "$sent_iTX" "$cli_target"
				        echo "[$target] : Confirmed import $sent_iTX at $(date)"
		        		printbalance
		        		echo "********************************************************************************"
				else
                                        echo "**** Skipping Migration  ************************************"
                                        echo "**** $source chain has less balance than $target chain at $(date) ****"
			        fi
			done
		else
                        echo "**** Skipping Migration  ************************************"
                        echo "**** Source $source chain is also target $target chain at $(date) ****"

		fi
	done
done
