#!/bin/bash

N=40

for i in `seq 1 $1`
do
    (
	username=posit`printf %04i $i`
    	if ( ! id $username >& /dev/null ); then 	
        while true
            do  
		sleep `echo 2*$(( $i % $N ))/$N | bc -l`
                echo creating user $username
		if ( ! id $username >& /dev/null ); then 
			expect create-users.exp $username {{user_password}} >& /dev/null 
		fi
		sleep 5 
		if ( echo {{user_password}} | pamtester login $username authenticate ); then  
                    break 
                fi
            done
	fi
    ) &
    if [[ $(jobs -r -p | wc -l) -ge $N ]]; then
        wait -n
    fi
done

wait

