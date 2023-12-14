#!/bin/bash

N=20

for i in \`seq 1 \$1\`
do
    (	
        while true
            do
                username=posit\`printf %04i \$i\`
	            expect create-users.exp \$username {{user_password}} 
                echo {{user_password}} | pamtester login \$username authenticate
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

