aws secretsmanager create-secret \
    --name PWBADSecretPWD \
    --description "Secret for simpleAD integration read-only password" \
    --secret-string "Testme123!"
