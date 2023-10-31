#!/bin/bash

N=10

for i in `seq 1 $1`
do
    (	
	expect create-users.exp posit`printf %04i $i` Testme1234
    ) &
    if [[ $(jobs -r -p | wc -l) -ge $N ]]; then
        wait -n
    fi
done

wait

