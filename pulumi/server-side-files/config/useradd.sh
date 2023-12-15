#!/bin/bash

N=20

for i in \`seq 1 \$1\`
do
    (	
        while true
            do
                username=posit\`printf %04i \$i\`
                if ( ! id \$username >& /dev/null ); then
                    echo "creating user \$username"
	                expect create-users.exp \$username {{user_password}} >& /dev/null
                    #echo {{user_password}} | pamtester login \$username authenticate
                else
                    echo "user \$username already exists"
                fi
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

