for i in `pcluster list-images --image-status AVAILABLE | grep imageId | awk '{print $2}' | sed 's#"##g' | sed 's#,##'`; do pcluster delete-image -i $i ; done
pcluster describe-image  -i master-ukhsa4
pcluster  list-image-log-streams -i master-ukhsa4
pcluster get-image-log-events  -i master-ukhsa4 --log-stream-name 3.7.2/1

