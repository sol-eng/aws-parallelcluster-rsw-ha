#!/bin/bash

N=20

for i in \`seq 1 \$1\`
do
    (	
        while true
            do
                username=posit\`printf %04i \$i\`
	            expect create-users.exp \$username Testme1234
                echo "Testme1234" | pamtester login posit0001 authenticate
                if [ \$? -eq 0 ]; then
                    break 
                fi
            done
    ) &
    if [[ \$(jobs -r -p | wc -l) -ge \$N ]]; then
        wait -n
    fi
done

wait

