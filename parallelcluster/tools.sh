aws secretsmanager create-secret \
    --name PWBADSecret \
    --description "Secret for simpleAD integration read-only password" \
    --secret-string "TestMe123!"
